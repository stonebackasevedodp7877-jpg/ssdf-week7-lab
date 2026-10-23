#!/usr/bin/env python3
"""Explain why two release archives built from the same commit differ.

    python3 scripts/diagnose_drift.py A.tar.gz B.tar.gz

Looks at the three layers where a non-reproducible build hides its noise
(build_drift_findings.md):
  1. gzip header      - timestamp / original file name stored by gzip
  2. tar metadata     - entry order, mtimes, owner, mode
  3. file contents    - embedded wall-clock dates, absolute build paths,
                        and Go source files present in only one binary
Python 3.9+ standard library only (runs on macOS and Linux).
"""
import gzip
import hashlib
import re
import struct
import sys
import tarfile
from datetime import datetime, timezone

DATE_RE = re.compile(rb"20\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ")
STRINGS_RE = re.compile(rb"[\x21-\x7e]{6,}")
RELGO_RE = re.compile(rb"((?:cmd|internal|tools)/[A-Za-z0-9_./-]+\.go)$")
MAIN_GO = b"/cmd/healthsync/main.go"


def gzip_header(path):
    with open(path, "rb") as f:
        head = f.read(10)
    flags, mtime = head[3], struct.unpack("<I", head[4:8])[0]
    return {"mtime": mtime, "fname": bool(flags & 0x08), "os": head[9]}


def members(path):
    out = []
    with tarfile.open(path, "r:gz") as tf:
        for m in tf.getmembers():
            data = tf.extractfile(m).read() if m.isfile() else b""
            out.append((m, data))
    return out


def fmt_time(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC") if t else "0 (not set)"


def strings_of(data):
    return set(STRINGS_RE.findall(data))


def abs_paths(strs):
    """Checkout directory recorded by the compiler (absent with -trimpath)."""
    return {x[: -len(MAIN_GO)].decode() for x in strs if x.startswith(b"/") and x.endswith(MAIN_GO)}


def go_files(strs, roots):
    """Project source files compiled into the binary, relative to the module root.

    With -trimpath the compiler records "healthsync/<file>"; without it, the
    absolute checkout directory. Either way we strip the root before comparing.
    """
    out = set()
    for x in strs:
        if not x.endswith(b".go"):
            continue
        for r in roots:
            if x.startswith(r + b"/"):
                out.add(x[len(r) + 1:].decode())
                break
    return out


def main(a, b):
    found = 0
    ga, gb = gzip_header(a), gzip_header(b)
    if ga != gb:
        found += 1
        print(f"[gzip header] mtime {fmt_time(ga['mtime'])} vs {fmt_time(gb['mtime'])}; "
              f"stores file name: {ga['fname']} vs {gb['fname']}")

    ma, mb = members(a), members(b)
    na, nb = [m.name for m, _ in ma], [m.name for m, _ in mb]
    if na != nb:
        found += 1
        if sorted(na) == sorted(nb):
            print(f"[tar order] same entries, different order: {na} vs {nb}")
        else:
            print(f"[tar entries] only in A: {sorted(set(na) - set(nb))}; only in B: {sorted(set(nb) - set(na))}")

    db = {m.name: (m, d) for m, d in mb}
    meta_diffs, content_diffs = [], []
    for m, d in ma:
        if m.name not in db:
            continue
        m2, d2 = db[m.name]
        for attr in ("mtime", "uid", "gid", "uname", "gname", "mode"):
            v1, v2 = getattr(m, attr), getattr(m2, attr)
            if v1 != v2:
                if attr == "mtime":
                    v1, v2 = fmt_time(v1), fmt_time(v2)
                elif attr == "mode":
                    v1, v2 = oct(v1), oct(v2)
                meta_diffs.append(f"{m.name}: {attr} {v1} vs {v2}")
        if d != d2:
            content_diffs.append((m.name, d, d2))

    if meta_diffs:
        found += 1
        print(f"[tar metadata] {len(meta_diffs)} header field(s) differ, e.g.:")
        for line in meta_diffs[:6]:
            print(f"    {line}")

    for name, d1, d2 in content_diffs:
        found += 1
        n = sum(1 for x, y in zip(d1, d2) if x != y) + abs(len(d1) - len(d2))
        print(f"[content] {name}: sha256 {hashlib.sha256(d1).hexdigest()[:12]} vs "
              f"{hashlib.sha256(d2).hexdigest()[:12]}, {n} byte(s) differ, size {len(d1)} vs {len(d2)}")
        dates1, dates2 = set(DATE_RE.findall(d1)), set(DATE_RE.findall(d2))
        if dates1 != dates2:
            print(f"    embedded timestamp: {sorted(x.decode() for x in dates1 - dates2)} vs "
                  f"{sorted(x.decode() for x in dates2 - dates1)}  <- wall clock of the build host")
        s1, s2 = strings_of(d1), strings_of(d2)
        p1, p2 = abs_paths(s1), abs_paths(s2)
        if p1 != p2:
            print(f"    absolute build path: {sorted(p1)} vs {sorted(p2)}  <- checkout directory baked in")
        g1 = go_files(s1, [x.encode() for x in p1] + [b"healthsync"])
        g2 = go_files(s2, [x.encode() for x in p2] + [b"healthsync"])
        if g1 != g2:
            print(f"    source files only in A: {sorted(g1 - g2)}; only in B: {sorted(g2 - g1)}  "
                  f"<- code that is not in the reviewed commit")

    if not found:
        print("archives are identical")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
