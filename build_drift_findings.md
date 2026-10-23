# Task 1 - Break It: Why the Starter Build Is Not Reproducible (PO.3.2)

**Build inspected:** `reference/Makefile.starter` (the HealthSync starter build, unchanged)
**Fixed build:** `Makefile` + `tools/reprotar` (release `v1.0.0`, commit `c1c4f83`)
**Method:** `scripts/builder.sh` checks out the same commit into fresh directories and builds it
as an independent builder would; `scripts/compare_builds.sh` and `scripts/diagnose_drift.py`
compare the release archives layer by layer (gzip header, tar headers, file contents).
All values below are from `verification_log.txt` (run of 2026-10-23 UTC).

## Result

SHA-256 of `healthsync-1.0.0-linux-amd64.tar.gz`, first 8 hex digits:

| Build | Builder A | Builder B | Builder C | Verdict |
|---|---|---|---|---|
| Starter Makefile, same commit, two checkouts, 2 s apart | `06a0261c` | `34de4362` | - | **DIFFERENT** |
| Reproducible Makefile, three deliberately different builders | `ed805f28` | `ed805f28` | `ed805f28` | **IDENTICAL** |
| GitHub Actions, ubuntu-24.04 vs macos-15, same commit | `ed805f28` | `ed805f28` | - | **IDENTICAL**, and equal to the local build |

Builder A: clone, TZ=UTC, umask 022. Builder B: clone in a deeper path, TZ=Asia/Shanghai,
umask 077, LANG=en_US.UTF-8, later. Builder C: third-party rebuild from a `git archive` source
export with no `.git` directory, TZ=America/Chicago.

## Findings

| # | Difference | Evidence from `diagnose_drift.py` | Why it matters | SSDF | Fix in `Makefile` |
|---:|---|---|---|---|---|
| 1 | **Embedded timestamp.** `BUILD_DATE := $(shell date ...)` is linked into the binary with `-X main.buildDate`. | binary contains `2026-10-23T05:07:21Z` vs `2026-10-23T05:07:59Z` | Every build differs, so a changed byte is never suspicious. | PO.3.2 | `BUILD_DATE` derived from `SOURCE_DATE_EPOCH` = commit time (`git log -1 --format=%ct`); the build refuses to fall back to the wall clock. |
| 2 | **Absolute build path.** The Go compiler records the full source path of every file (stack traces, debug info). | `/tmp/ssdf-w7.kDrQYg/starter/a/src/healthsync` vs `/tmp/ssdf-w7.kDrQYg/starter/other-checkout/b/src/healthsync` | Two checkouts never match; the binary also leaks the build host's directory layout. | PO.3.2, PO.5.1 | `-trimpath` (paths become `healthsync/...`), `-buildvcs=false`, `-buildid=`; commit injected explicitly so a source-archive rebuild matches a git checkout. |
| 3 | **Archive metadata.** Host `tar -czf` stores each file's mtime (the checkout/build time), the builder's uid/gid and user names, modes after the local umask, and entries in filesystem order. | 4 tar header fields differ - every entry's mtime, e.g. `healthsync` 05:07:38 vs 05:08:16 UTC | Identical binaries still ship in different archives. GNU tar, bsdtar (macOS) and different gzip versions also write different bytes. | PO.3.2 | `tools/reprotar`: entries sorted, every mtime = `SOURCE_DATE_EPOCH`, uid/gid 0 with empty names, modes 0755/0644, USTAR headers, gzip header without name or time. Go standard library only, so it depends only on the pinned toolchain. |
| 4 | **Unpinned toolchain.** The starter uses whatever `go` is on `PATH`. | latent (both starter builds ran on one host) | A different compiler release changes code generation; the release cannot be rebuilt later. | PW.6.1, PO.3.2 | `toolchain go1.27.3` in `go.mod`, `GOTOOLCHAIN` exported by the Makefile (exact release, fetched and checked against the Go checksum database if missing), `make verify-toolchain` fails on mismatch. |
| 5 | **Dependencies resolved at build time.** Modules are downloaded from the network during the build. | latent | Build result depends on network state; the builder needs internet access. | PO.5.1, PW.4.4 | `vendor/` locked by `go.sum`, `GOFLAGS=-mod=vendor`; CI builds with `GOPROXY=off`, and the `test` job runs `go mod verify` and checks `vendor/` against `go.sum`. |
| 6 | **cgo on by default.** A native build links through the host C toolchain. | latent | The host's compiler and libc become hidden build inputs. | PW.6.1 | `CGO_ENABLED=0` (pure-Go static binary). |

## Each fix is necessary (TASK 2.3)

Starting from the reproducible Makefile and removing one fix at a time brings the drift back:

| Fix removed | Result | What `diagnose_drift.py` reports |
|---|---|---|
| `-trimpath` | DIFFERENT | absolute build path differs |
| `SOURCE_DATE_EPOCH` (wall-clock `BUILD_DATE`) | DIFFERENT | embedded timestamp differs |
| `tools/reprotar` (host `tar -czf` on byte-identical files) | DIFFERENT | tar mtimes differ while every file's content is identical |

## Which differences could an attacker hide behind?

All of them. While any noise remains, two builds of the same commit never match, so nobody
can tell harmless drift from a tampered build host. Once the build is reproducible, a single
changed byte becomes evidence. TASK 2.4 shows this: a compromised builder that adds one source
file after checkout (the SolarWinds/SUNSPOT pattern, where the reviewed source stays clean)
produces `46c07b6b` instead of `ed805f28`, and the rebuild-and-compare gate fails with
`source files only in B: ['cmd/healthsync/zz_build_implant.go']`.

## Limits: reproducible is not the same as secure

Matching hashes prove the build is deterministic. They do not prove that the source, the
vendored dependency or the compiler is benign: an implant committed to the repository, or a
backdoored toolchain used by every builder, is reproduced faithfully. Mitigations in this
repository: builders on two different operating systems (ubuntu-24.04 and macos-15) and a
third-party source-archive rebuild; a toolchain fetched by exact version and checked against
the Go checksum database; `go mod verify`; actions pinned to commit SHAs; and the signature,
which binds the release to the reviewed commit and this workflow. Code review (PW.7) and
dependency review remain necessary.
