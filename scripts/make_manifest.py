#!/usr/bin/env python3
"""Write the HealthSync release manifest (SSDF PS.3.1, PS.3.2).

The manifest is the provenance record archived with every release: which
commit, which toolchain and build flags, which dependencies, which builders
agreed on the bytes, the artifact hashes, the SBOM, and how to verify the
signature. A later vulnerability investigation starts from these facts.

    python3 scripts/make_manifest.py --release-dir release --repo-url URL \
        --commit SHA --ref v1.0.0 --source-date-epoch N --go-version go1.27.3 \
        --builder "A: ubuntu, /path/a, TZ=UTC" --builder-sums A=path/SHA256SUMS ... \
        --sbom release/sbom.cyclonedx.json --signing "cosign key-pair: cosign.pub" \
        --out release/release-manifest.json
Python 3.9+ standard library only.
"""
import argparse
import hashlib
import json
import os
import re
from datetime import datetime, timezone


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_sums(path):
    out = {}
    with open(path) as f:
        for line in f:
            if line.strip():
                digest, name = line.split(None, 1)
                out[name.strip().lstrip("*")] = digest
    return out


def dependencies(root):
    sums = {}
    gosum = os.path.join(root, "go.sum")
    if os.path.exists(gosum):
        for line in open(gosum):
            mod, ver, h = line.split()
            if not ver.endswith("/go.mod"):
                sums[(mod, ver)] = h
    deps = []
    modules = os.path.join(root, "vendor", "modules.txt")
    if os.path.exists(modules):
        for line in open(modules):
            m = re.match(r"^# (\S+) (\S+)$", line.strip())
            if m:
                mod, ver = m.groups()
                deps.append({"module": mod, "version": ver, "go_sum": sums.get((mod, ver)),
                             "purl": f"pkg:golang/{mod}@{ver}", "source": "vendor/ (no network at build time)"})
    return deps


def makefile_var(root, var):
    text = open(os.path.join(root, "Makefile")).read()
    m = re.search(rf"^{var}\s*:?=\s*(.+)$", text, re.M)
    return m.group(1).strip() if m else None


def makefile_flags(root):
    return {"go_build": "go build -trimpath -buildvcs=false -ldflags \"-buildid= -X main.version=... "
                        "-X main.commit=<commit> -X main.buildDate=<SOURCE_DATE_EPOCH as UTC>\"",
            "env": {"CGO_ENABLED": "0", "GOFLAGS": "-mod=vendor", "TZ": "UTC", "LC_ALL": "C",
                    "GOTOOLCHAIN": "<toolchain line of go.mod>"},
            "targets": (makefile_var(root, "TARGETS") or "").split(),
            "packager": "tools/reprotar (sorted entries, mtime=SOURCE_DATE_EPOCH, uid/gid 0, "
                        "modes 0755/0644, USTAR, gzip without name/time)"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--release-dir", required=True)
    ap.add_argument("--repo-url", required=True)
    ap.add_argument("--commit", required=True)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--source-date-epoch", type=int, required=True)
    ap.add_argument("--go-version", required=True)
    ap.add_argument("--project-root", default=".")
    ap.add_argument("--builder", action="append", default=[], help="NAME: description")
    ap.add_argument("--builder-sums", action="append", default=[], help="NAME=path/to/SHA256SUMS")
    ap.add_argument("--sbom")
    ap.add_argument("--signing", required=True)
    ap.add_argument("--built-by", default="local workstation (run_lab.sh)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    rel = a.release_dir
    published = read_sums(os.path.join(rel, "SHA256SUMS"))
    artifacts = []
    for name in sorted(published):
        p = os.path.join(rel, name)
        actual = sha256(p)
        if actual != published[name]:
            raise SystemExit(f"{name}: SHA256SUMS says {published[name]}, file is {actual}")
        artifacts.append({"name": name, "sha256": actual, "size": os.path.getsize(p)})

    descr = dict(b.split(":", 1) for b in a.builder)
    builders, agree = [], True
    for spec in a.builder_sums:
        name, path = spec.split("=", 1)
        sums = read_sums(path)
        same = all(sums.get(x["name"]) == x["sha256"] for x in artifacts)
        agree &= same
        builders.append({"name": name, "environment": descr.get(name, "").strip(),
                         "sha256": {k: sums[k] for k in sorted(sums)}, "matches_release": same})

    manifest = {
        "schema": "healthsync.release-manifest/v1",
        "project": "HealthSync",
        "version": makefile_var(a.project_root, "VERSION"),
        "source": {
            "repository": a.repo_url,
            "ref": a.ref,
            "commit": a.commit,
            "source_date_epoch": a.source_date_epoch,
            "source_date_utc": datetime.fromtimestamp(a.source_date_epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
        "toolchain": {"go": a.go_version, "pinned_by": "go.mod toolchain directive + GOTOOLCHAIN",
                      "build": makefile_flags(a.project_root)},
        "dependencies": dependencies(a.project_root),
        "reproducibility": {"builders": builders, "all_identical": agree and len(builders) >= 2,
                            "gate": "scripts/compare_builds.sh (CI job `compare`)"},
        "artifacts": artifacts,
        "sbom": ({"file": os.path.basename(a.sbom), "format": "CycloneDX JSON", "sha256": sha256(a.sbom)}
                 if a.sbom else None),
        "verification": {
            "hash_list": "SHA256SUMS",
            "hash_list_signature": "SHA256SUMS.sigstore.json",
            "manifest_signature": os.path.basename(a.out) + ".sigstore.json",
            "signing": a.signing,
            "verify_command": "scripts/verify_release.sh <release-dir> --key cosign.pub",
        },
        "built_by": a.built_by,
        "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    with open(a.out, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"wrote {a.out}: {len(artifacts)} artifacts, {len(manifest['dependencies'])} dependencies, "
          f"builders identical={manifest['reproducibility']['all_identical']}")


if __name__ == "__main__":
    main()
