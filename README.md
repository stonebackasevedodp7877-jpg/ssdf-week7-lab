# HealthSync - SSDF Week 7: Secure Build & Release Processes

HealthSync receives vital-sign readings (heart rate, SpO2, blood pressure,
temperature) from patient wearables and serves them to the clinic dashboard.
This repository makes its release **reproducible, gated and verifiable**:
anyone can rebuild a tagged commit and get the same bytes, CI refuses to sign
a release unless two independent builders agree, and consumers verify a signed
hash list before trusting a download.

NIST SP 800-218 (SSDF) practices covered: PO.3.2 (Example 4, reproducible
builds), PO.5.1, PW.6.1, PW.6.2, PS.2.1, PS.3.1, PS.3.2.

## Rebuild a release yourself

```bash
git clone https://github.com/stonebackasevedodp7877-jpg/ssdf-week7-lab && cd ssdf-week7-lab
git checkout v1.0.0
make release            # any Go >= 1.21 on PATH; the pinned go1.27.3 is fetched and checksum-verified
shasum -a 256 dist/*.tar.gz
```

The hashes must equal the `SHA256SUMS` attached to the GitHub Release and the
ones recorded in `release/release-manifest.json` - on Linux or macOS, in any
directory, in any time zone.

## What makes the build reproducible

| Hidden input | Starter build (`reference/Makefile.starter`) | Reproducible build (`Makefile`) |
|---|---|---|
| Clock | `BUILD_DATE := $(shell date ...)` | date derived from `SOURCE_DATE_EPOCH` = commit time |
| Build directory | compiler records absolute paths | `-trimpath`, `-buildvcs=false`, `-buildid=` |
| Archive metadata | host `tar -czf`: mtimes, owner, order, gzip header | `tools/reprotar`: sorted, mtime = commit time, uid/gid 0, fixed modes, no gzip timestamp |
| Toolchain | whatever `go` is on PATH | `toolchain go1.27.3` in go.mod + `GOTOOLCHAIN` |
| Dependencies | resolved at build time | `vendor/` locked by `go.sum`, `GOFLAGS=-mod=vendor`, `GOPROXY=off` in CI |
| Host C toolchain | cgo on by default | `CGO_ENABLED=0` |

Root-cause analysis of the starter build: [build_drift_findings.md](build_drift_findings.md).

## CI: `.github/workflows/reproducible_release.yml`

`test` -> `build` (A: ubuntu-24.04, B: macos-15; different paths, TZ, umask)
-> `compare` (fails if the archives differ by one byte) -> `sign` (keyless
cosign, separate job, SLSA provenance) -> `verify` (consumer check + negative
tests) -> `archive` (evidence kept as a separate artifact; GitHub Release on
`v*` tags).

## Verify a release

```bash
# release signed in CI (keyless, identity pinned to the workflow)
scripts/verify_release.sh <dir> \
  --identity "https://github.com/stonebackasevedodp7877-jpg/ssdf-week7-lab/.github/workflows/reproducible_release.yml@refs/tags/v1.0.0" \
  --issuer https://token.actions.githubusercontent.com

# release signed locally by run_lab.sh (key pair; public key in cosign.pub)
scripts/verify_release.sh release --key cosign.pub
```

## Lab runner

`./run_lab.sh` runs the whole lab end to end (Break It, Fix It, Sign & Verify)
and writes every command with its real output to `verification_log.txt`.

| Path | Purpose |
|---|---|
| `cmd/healthsync`, `internal/vitals` | the service |
| `Makefile` | reproducible release build |
| `reference/Makefile.starter` | starter build, kept unchanged for TASK 1 |
| `tools/reprotar` | deterministic tar.gz writer (Go standard library only) |
| `scripts/builder.sh` | one isolated builder (own checkout, cache, TZ, umask; optional tamper) |
| `scripts/compare_builds.sh` | rebuild-and-compare gate, used locally and in CI |
| `scripts/diagnose_drift.py` | explains why two archives differ |
| `scripts/make_manifest.py` | release manifest (commit, toolchain, deps, builders, hashes, SBOM) |
| `scripts/verify_release.sh` | consumer-side verification |
| `release/` | signed hash list, SBOM and manifest from the local lab run |
