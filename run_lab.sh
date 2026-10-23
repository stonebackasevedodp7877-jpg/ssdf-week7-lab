#!/usr/bin/env bash
# =============================================================================
# SSDF Week 7 lab runner - Secure Build & Release Processes (HealthSync)
#
#   TASK 1  Break It    build the starter project twice, find out why the same
#                       commit yields different hashes
#   TASK 2  Fix It      deterministic build; independent builders must agree;
#                       prove each fix is necessary; the rebuild-and-compare
#                       gate (the CI `compare` job) rejects a tampered builder
#   TASK 3  Sign/Verify sign the hash list with a key kept off the build hosts,
#                       verify, reject tampered / forged / wrongly-signed
#                       releases, archive a signed release manifest + SBOM
#   -> package [Student]_SSDF_Week7.zip
#
# Every command and its real output is appended to verification_log.txt.
# Works on macOS (bash 3.2, make 3.81) and Ubuntu 22.04+/WSL2.
#
# Usage:  ./run_lab.sh                         (defaults below)
#         STUDENT=ShuchenMeng REF=v1.0.0 ./run_lab.sh
# Needs: git, make, go (any version; the pinned toolchain is fetched and
#        checksum-verified by the go command), python3, cosign, syft, shasum, zip
# =============================================================================
set -uo pipefail

STUDENT="${STUDENT:-ShuchenMeng}"
VERSION="1.0.0"
LINUX_PKG="healthsync-${VERSION}-linux-amd64.tar.gz"
LOG="verification_log.txt"
EV="evidence"
REL="release"
SIGNER_DIR="${SIGNER_DIR:-$HOME/.ssdf-week7-signer}"        # signing key lives here, never in a build dir
ARCHIVE_ROOT="${ARCHIVE_ROOT:-$HOME/.ssdf-week7-archive}"    # evidence store, apart from release files
export COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"                # lab-only key, empty password (as in Week 6)

cd "$(dirname "$0")" || exit 1
ROOT="$(pwd)"
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/ssdf-w7.XXXXXX")}"
mkdir -p "$EV" "$REL"
rm -f "$EV"/*.txt "$REL"/*
: > "$LOG"

# ----------------------------------------------------------------- helpers ---
log()     { printf '%s\n' "$*" | tee -a "$LOG"; }
section() { log ""; log "=========================================================================="; log "$*"; log "=========================================================================="; }
run() {
  log "\$ $*"
  "$@" 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  log "[exit code: ${rc}]"
  return "$rc"
}
die()  { log "FATAL: $*"; echo; echo ">>> 运行中止：$*（详见 ${LOG}）" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
short() { shasum -a 256 "$1" | cut -c1-8; }
# gate OUTFILE FILTER DIR...: run the rebuild-and-compare gate, keep its full output in
# OUTFILE, log either everything (FILTER empty) or only the lines matching FILTER.
gate() {
  local out="$1" filter="$2"; shift 2
  log "\$ scripts/compare_builds.sh $*"
  scripts/compare_builds.sh "$@" > "$out" 2>&1
  local rc=$?
  if [ -z "$filter" ]; then tee -a "$LOG" < "$out"; else grep -E "$filter" "$out" | tee -a "$LOG"; fi
  log "[exit code: ${rc}]"
  return "$rc"
}
expect_fail() { if [ "$1" -ne 0 ]; then log "RESULT: rejected as expected"; return 0; else log "RESULT: UNEXPECTED PASS"; return 1; fi; }

# =============================================================================
section "SSDF Week 7 - Verification Log | student: ${STUDENT}"
for t in git make go python3 cosign syft shasum zip tar; do need "$t"; done
git rev-parse --git-dir >/dev/null 2>&1 || die "run_lab.sh must run inside the git checkout of the lab repo"

if [ -z "${REF:-}" ]; then
  if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then REF="v${VERSION}"; else REF="HEAD"; fi
fi
COMMIT="$(git rev-parse "${REF}^{commit}")" || die "unknown ref ${REF}"
EPOCH="$(git log -1 --format=%ct "$COMMIT")"
PINNED="$(git show "${COMMIT}:go.mod" | sed -n 's/^toolchain //p')"
REPO_URL="$(git remote get-url origin 2>/dev/null | sed 's/\.git$//')"

log "Date (UTC)        : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "Host              : $(uname -srm)"
log "git               : $(git --version)"
log "make              : $(make --version 2>/dev/null | head -1)"
log "go (on PATH)      : $(GOTOOLCHAIN=local go version)"
log "pinned toolchain  : ${PINNED}  (go.mod; the go command switches to it automatically)"
log "cosign            : $(cosign version 2>/dev/null | awk '/GitVersion/{print $2}')"
log "syft              : $(syft version 2>/dev/null | awk '/^Version/{print $2}')"
log "python            : $(python3 --version 2>&1)"
log "Repository        : ${REPO_URL:-local}"
log "Release ref       : ${REF} -> ${COMMIT}"
log "SOURCE_DATE_EPOCH : ${EPOCH} ($(TZ=UTC git log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd "$COMMIT"))  <- commit time, not wall clock"
log "Work directory    : ${WORK}"

# =============================================================================
section "TASK 1.1 - Break It: build the STARTER project twice from the same commit"
log "# Starter build = reference/Makefile.starter (wall-clock date, no -trimpath, host tar/gzip)."
log "# Builder A and builder B check out the same commit into different directories,"
log "# a few seconds apart - exactly what two CI runners or two developers would do."
run scripts/builder.sh A-starter . "$COMMIT" "$WORK/starter/a" reference/Makefile.starter \
  || die "starter build A failed"
sleep 2
run scripts/builder.sh B-starter . "$COMMIT" "$WORK/starter/other-checkout/b" reference/Makefile.starter \
  || die "starter build B failed"
SA="$(short "$WORK/starter/a/out/$LINUX_PKG")"; SB="$(short "$WORK/starter/other-checkout/b/out/$LINUX_PKG")"
log ""
log "BEFORE: STARTER MAKEFILE  (SHA-256 of ${LINUX_PKG}, first 8 hex digits)"
log "  Build A  ${SA}..."
log "  Build B  ${SB}..."
if [ "$SA" != "$SB" ]; then log "  DIFFERENT"; DRIFT_RC=0; else log "  identical (unexpected)"; DRIFT_RC=1; fi

section "TASK 1.2 - Diagnose: where do the two starter builds differ?"
gate "$EV/task1_starter_compare.txt" "" "$WORK/starter/a/out" "$WORK/starter/other-checkout/b/out"
STARTER_GATE_RC=$?
log "# -> gate result on the starter build: exit ${STARTER_GATE_RC} (a CI rebuild-and-compare job would block this release)"
log "# Root causes (see build_drift_findings.md):"
log "#   embedded timestamp   - BUILD_DATE from \`date\` on the build host"
log "#   absolute build path  - compiler records the checkout directory (no -trimpath)"
log "#   archive metadata     - tar stores per-file mtimes of the fresh checkout/build"

# =============================================================================
section "TASK 2.1 - Fix It: pinned inputs of the reproducible build"
git -C "$ROOT" show "${COMMIT}:Makefile" > "$WORK/Makefile.fixed"
log "\$ diff -u reference/Makefile.starter Makefile   (key changes)"
diff -u "$ROOT/reference/Makefile.starter" "$WORK/Makefile.fixed" | grep -E '^[+-][^+-]' \
  | grep -E 'trimpath|SOURCE_DATE_EPOCH|BUILD_DATE|GOTOOLCHAIN|GOFLAGS|CGO_ENABLED|reprotar|buildvcs|tar -czf' \
  | grep -vE 'echo|^\+#' | tee -a "$LOG"
run make -s -C "$WORK/starter/a/src/healthsync" -f "$WORK/Makefile.fixed" print-inputs
log "vendored dependencies (locked by go.sum):"
git show "${COMMIT}:vendor/modules.txt" | grep '^# ' | tee -a "$LOG"

section "TASK 2.2 - Three independent builders, deliberately different environments"
log "# A: clone, TZ=UTC,               umask 022, LANG=C"
log "# B: clone, TZ=Asia/Shanghai,     umask 077, LANG=en_US.UTF-8, deeper path, later"
log "# C: third-party rebuild from a \`git archive\` source export (no .git),"
log "#    TZ=America/Chicago, COMMIT and SOURCE_DATE_EPOCH passed in explicitly"
run scripts/builder.sh A . "$COMMIT" "$WORK/builder-a" || die "builder A failed"
sleep 2
BUILDER_TZ=Asia/Shanghai BUILDER_UMASK=077 BUILDER_LANG=en_US.UTF-8 \
  run scripts/builder.sh B . "$COMMIT" "$WORK/runner-2/home/ci/_work/HealthSync/builder-b" || die "builder B failed"
sleep 2
EXPORT_ONLY=1 BUILDER_TZ=America/Chicago \
  run scripts/builder.sh C . "$COMMIT" "$WORK/third-party/builder-c" || die "builder C failed"
BA="$WORK/builder-a/out"; BB="$WORK/runner-2/home/ci/_work/HealthSync/builder-b/out"; BC="$WORK/third-party/builder-c/out"
gate "$EV/task2_reproducible_compare.txt" "" "$BA" "$BB" "$BC"
REPRO_RC=$?
log ""
log "AFTER: REPRODUCIBLE MAKEFILE  (SHA-256 of ${LINUX_PKG}, first 8 hex digits)"
log "  Build A  $(short "$BA/$LINUX_PKG")..."
log "  Build B  $(short "$BB/$LINUX_PKG")..."
log "  Build C  $(short "$BC/$LINUX_PKG")..."
[ "$REPRO_RC" -eq 0 ] && log "  IDENTICAL" || log "  DIFFERENT (unexpected)"

section "TASK 2.3 - Each fix is necessary: remove one fix at a time, builds must drift again"
ABL_OK=0
export BUILDER_GOCACHE="$WORK/shared-gocache"   # speed only: these builds are expected to differ
log "# (ablation builders share one Go build cache for speed; builders A, B, C and T above/below each use a fresh one)"
log "# (a) without -trimpath, two checkouts in different directories"
MAKE_ARGS="TRIMPATH=" run scripts/builder.sh noTrim-1 . "$COMMIT" "$WORK/ablation/trim/one" >/dev/null || die "ablation build failed"
MAKE_ARGS="TRIMPATH=" run scripts/builder.sh noTrim-2 . "$COMMIT" "$WORK/ablation/trim/two/deeper" >/dev/null || die "ablation build failed"
gate "$EV/task2_ablation_trimpath.txt" "MISMATCH|absolute build path|GATE" "$WORK/ablation/trim/one/out" "$WORK/ablation/trim/two/deeper/out"
expect_fail $? || ABL_OK=1

log "# (b) wall-clock BUILD_DATE instead of SOURCE_DATE_EPOCH (same directory name, builds 2 s apart)"
MAKE_ARGS="BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" run scripts/builder.sh clock-1 . "$COMMIT" "$WORK/ablation/clock/one/b" >/dev/null || die "ablation build failed"
sleep 2
MAKE_ARGS="BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" run scripts/builder.sh clock-2 . "$COMMIT" "$WORK/ablation/clock/two/b" >/dev/null || die "ablation build failed"
gate "$EV/task2_ablation_clock.txt" "MISMATCH|embedded timestamp|GATE" "$WORK/ablation/clock/one/b/out" "$WORK/ablation/clock/two/b/out"
expect_fail $? || ABL_OK=1

log "# (c) host tar/gzip instead of tools/reprotar: repack builder A's IDENTICAL files twice"
mkdir -p "$WORK/ablation/tar/x" "$WORK/ablation/tar/y"
tar -xzf "$BA/$LINUX_PKG" -C "$WORK/ablation/tar"
P="${LINUX_PKG%.tar.gz}"
for d in x y; do
  mkdir -p "$WORK/ablation/tar/$d/stage/$P" "$WORK/ablation/tar/$d/out"
  cp "$WORK/ablation/tar/$P"/* "$WORK/ablation/tar/$d/stage/$P/"      # fresh copies: new mtimes, builder's owner
  tar -czf "$WORK/ablation/tar/$d/out/$LINUX_PKG" -C "$WORK/ablation/tar/$d/stage" "$P"
  sleep 2
done
gate "$EV/task2_ablation_hosttar.txt" "MISMATCH|\[gzip|\[tar|\[content|/healthsync: mtime|GATE" "$WORK/ablation/tar/x/out" "$WORK/ablation/tar/y/out"
expect_fail $? || ABL_OK=1
unset BUILDER_GOCACHE

section "TASK 2.4 - Rebuild-and-compare gate catches a compromised builder"
log "# Builder T checks out the same commit, then the (simulated) compromised host slips an"
log "# extra source file into the tree before compiling - the SolarWinds pattern: the reviewed"
log "# source is clean, the implant only exists inside the build."
TAMPER=1 run scripts/builder.sh T-compromised . "$COMMIT" "$WORK/compromised/builder-t" || die "builder T failed"
gate "$EV/task2_tampered_builder_compare.txt" "" "$BA" "$WORK/compromised/builder-t/out"
expect_fail $?; GATE_OK=$?

log ""
log "# The same gate runs in CI: .github/workflows/reproducible_release.yml"
log "#   build (matrix: ubuntu-24.04 + macos-15) -> compare (scripts/compare_builds.sh) -> sign -> verify -> archive"
if command -v actionlint >/dev/null 2>&1; then
  run actionlint .github/workflows/reproducible_release.yml && log "actionlint: workflow is valid"
else
  log "(actionlint not installed - skipped static check)"
fi

# =============================================================================
section "TASK 3.1 - Release files and hash list"
cp "$BA"/*.tar.gz "$REL/"
( cd "$REL" && LC_ALL=C shasum -a 256 *.tar.gz > SHA256SUMS )
log "\$ cat ${REL}/SHA256SUMS"; tee -a "$LOG" < "$REL/SHA256SUMS"

section "TASK 3.2 - Sign the hash list with a key that never touches the build hosts"
mkdir -p "$SIGNER_DIR"; chmod 700 "$SIGNER_DIR"
if [ ! -f "$SIGNER_DIR/cosign.key" ]; then
  ( cd "$SIGNER_DIR" && cosign generate-key-pair >/dev/null 2>&1 ) || die "key generation failed"
fi
cp "$SIGNER_DIR/cosign.pub" "$ROOT/cosign.pub"
log "Signing key  : ${SIGNER_DIR}/cosign.key  (outside the repo and every builder directory)"
log "Public key   : cosign.pub  sha256=$(shasum -a 256 cosign.pub | cut -c1-64)"
tee -a "$LOG" < cosign.pub
SIGN_FLAGS=""
if curl -sf -m 8 -o /dev/null https://tuf-repo-cdn.sigstore.dev/root.json; then
  log "Sigstore TUF reachable -> signature is also logged in the Rekor transparency log"
else
  SIGN_FLAGS="--use-signing-config=false --tlog-upload=false"
  log "Sigstore public-good TUF/Rekor not reachable from this host -> offline key signature"
  log "(transparency-log signing is done by the CI 'sign' job with keyless OIDC certificates)"
fi
# shellcheck disable=SC2086
run cosign sign-blob --key "$SIGNER_DIR/cosign.key" $SIGN_FLAGS --yes \
  --bundle "$REL/SHA256SUMS.sigstore.json" "$REL/SHA256SUMS" || die "cosign sign-blob failed"

section "TASK 3.3 - Verify the release as a consumer would"
run scripts/verify_release.sh "$REL" --key cosign.pub
SIG_RC=$?

section "TASK 3.4 - NEGATIVE: tampered artifact (implanted binary, original hash list)"
A1="$WORK/attack/1"; mkdir -p "$A1"; cp "$REL"/* "$A1/"
cp "$WORK/compromised/builder-t/out/$LINUX_PKG" "$A1/$LINUX_PKG"
run scripts/verify_release.sh "$A1" --key cosign.pub
expect_fail $?; TAMPERED_OK=$?

section "TASK 3.5 - NEGATIVE: forged hash list (attacker also rewrites SHA256SUMS on the download page)"
A2="$WORK/attack/2"; mkdir -p "$A2"; cp "$A1"/* "$A2/"
( cd "$A2" && LC_ALL=C shasum -a 256 *.tar.gz > SHA256SUMS )
log "# The forged list now matches the implanted file, so a hash check alone passes:"
run sh -c "cd '$A2' && shasum -a 256 -c SHA256SUMS"
run scripts/verify_release.sh "$A2" --key cosign.pub
expect_fail $?; FORGED_OK=$?

section "TASK 3.6 - NEGATIVE: forged list re-signed with the attacker's own key"
( cd "$WORK/attack" && COSIGN_PASSWORD='' cosign generate-key-pair --output-key-prefix attacker >/dev/null 2>&1 )
cosign sign-blob --key "$WORK/attack/attacker.key" --use-signing-config=false --tlog-upload=false --yes \
  --bundle "$A2/SHA256SUMS.sigstore.json" "$A2/SHA256SUMS" >/dev/null 2>&1
run cosign verify-blob --key "$WORK/attack/attacker.pub" --insecure-ignore-tlog=true \
  --bundle "$A2/SHA256SUMS.sigstore.json" "$A2/SHA256SUMS"
log "# ^ valid for the attacker's key - which is exactly why consumers pin OUR key:"
run scripts/verify_release.sh "$A2" --key cosign.pub
expect_fail $?; UNTRUSTED_OK=$?
rm -f "$WORK/attack/attacker.key"

# =============================================================================
section "TASK 3.7 - SBOM of the shipped binary (provenance data, PS.3.2)"
mkdir -p "$WORK/sbom"; tar -xzf "$REL/$LINUX_PKG" -C "$WORK/sbom"
log "\$ (cd <extracted ${LINUX_PKG%.tar.gz}> && syft file:healthsync --source-name healthsync --source-version ${VERSION} -o cyclonedx-json=${REL}/sbom.cyclonedx.json -q)"
( cd "$WORK/sbom/${LINUX_PKG%.tar.gz}" && syft file:healthsync --source-name healthsync --source-version "$VERSION" \
    -o "cyclonedx-json=$ROOT/$REL/sbom.cyclonedx.json" -q ) 2>&1 | tee -a "$LOG"
[ -s "$REL/sbom.cyclonedx.json" ] || die "syft failed"
run python3 - "$REL/sbom.cyclonedx.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
print(f"bomFormat={b['bomFormat']} specVersion={b['specVersion']} components={len(b.get('components', []))}")
for c in b.get("components", []):
    print(f"  {c.get('type'):<12} {c.get('name')} {c.get('version', '')}  {c.get('purl', '')}")
PY

section "TASK 3.8 - Release manifest (commit, toolchain, dependencies, builders, hashes), signed"
run python3 scripts/make_manifest.py --release-dir "$REL" --project-root . \
  --repo-url "${REPO_URL:-local}" --commit "$COMMIT" --ref "$REF" --source-date-epoch "$EPOCH" \
  --go-version "$PINNED" \
  --builder "A: clone, TZ=UTC, umask 022" --builder-sums "A=$WORK/builder-a/SHA256SUMS" \
  --builder "B: clone, TZ=Asia/Shanghai, umask 077, other path" --builder-sums "B=$WORK/runner-2/home/ci/_work/HealthSync/builder-b/SHA256SUMS" \
  --builder "C: git-archive export, no .git, TZ=America/Chicago" --builder-sums "C=$WORK/third-party/builder-c/SHA256SUMS" \
  --sbom "$REL/sbom.cyclonedx.json" \
  --signing "cosign key pair; public key cosign.pub (sha256 $(shasum -a 256 cosign.pub | cut -c1-16)...)" \
  --built-by "local workstation $(uname -sm) via run_lab.sh" \
  --out "$REL/release-manifest.json" || die "manifest generation failed"
# shellcheck disable=SC2086
run cosign sign-blob --key "$SIGNER_DIR/cosign.key" $SIGN_FLAGS --yes \
  --bundle "$REL/release-manifest.json.sigstore.json" "$REL/release-manifest.json" || die "manifest signing failed"
log "\$ head -c 1200 ${REL}/release-manifest.json"; head -c 1200 "$REL/release-manifest.json" | tee -a "$LOG"; log ""

section "TASK 3.9 - Archive verification data APART from the release files (PS.3.1)"
ARCH="$ARCHIVE_ROOT/healthsync-${VERSION}-$(echo "$COMMIT" | cut -c1-12)"
[ -d "$ARCH" ] && chmod -R u+w "$ARCH" && rm -rf "$ARCH"
mkdir -p "$ARCH"
cp "$REL/SHA256SUMS" "$REL/SHA256SUMS.sigstore.json" "$REL/release-manifest.json" \
   "$REL/release-manifest.json.sigstore.json" "$REL/sbom.cyclonedx.json" cosign.pub "$ARCH/"
mkdir -p "$ARCH/builders"
cp "$WORK/builder-a/SHA256SUMS" "$ARCH/builders/A.SHA256SUMS"
cp "$WORK/runner-2/home/ci/_work/HealthSync/builder-b/SHA256SUMS" "$ARCH/builders/B.SHA256SUMS"
cp "$WORK/third-party/builder-c/SHA256SUMS" "$ARCH/builders/C.SHA256SUMS"
find "$ARCH" -type f -exec chmod 0444 {} +; find "$ARCH" -type d -exec chmod 0555 {} +   # read-only record
run ls -lR "$ARCH"
log "# Re-check the archived record on its own: manifest signature + its hashes vs. the release"
VERIFY_TLOG=""; grep -q '"tlogEntries"' "$ARCH/release-manifest.json.sigstore.json" || VERIFY_TLOG="--insecure-ignore-tlog=true"
# shellcheck disable=SC2086
run cosign verify-blob --key "$ARCH/cosign.pub" $VERIFY_TLOG \
  --bundle "$ARCH/release-manifest.json.sigstore.json" "$ARCH/release-manifest.json"
MAN_RC=$?
run python3 - "$ARCH/release-manifest.json" "$REL/SHA256SUMS" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
listed = dict((l.split()[1], l.split()[0]) for l in open(sys.argv[2]) if l.strip())
ok = all(listed.get(a["name"]) == a["sha256"] for a in m["artifacts"]) and len(listed) == len(m["artifacts"])
print(f"commit={m['source']['commit']} toolchain={m['toolchain']['go']} builders_identical={m['reproducibility']['all_identical']}")
print(f"manifest artifact hashes match the signed SHA256SUMS: {ok}")
sys.exit(0 if ok and m["reproducibility"]["all_identical"] else 1)
PY
ARCHIVE_RC=$(( MAN_RC + $? ))

# =============================================================================
section "SUMMARY"
ok()  { if [ "$1" -eq 0 ]; then echo PASS; else echo FAIL; fi; }
log "Release                               : ${REF} (${COMMIT})"
log "Release SHA-256 (${LINUX_PKG}) : $(shasum -a 256 "$REL/$LINUX_PKG" | cut -c1-64)"
log "Break It: starter builds drift        : $(ok "$DRIFT_RC")   (A ${SA}... vs B ${SB}...)"
log "Reproducible build (3 builders)       : $(ok "$REPRO_RC")   (all $(short "$BA/$LINUX_PKG")...)"
log "Each fix necessary (3 ablations)      : $(ok "$ABL_OK")"
log "CI gate rejects compromised builder   : $(ok "$GATE_OK")"
log "Signature (cosign verify-blob)        : $(ok "$SIG_RC")"
log "Tampered artifact rejected            : $(ok "$TAMPERED_OK")"
log "Forged hash list rejected             : $(ok "$FORGED_OK")"
log "Untrusted key rejected                : $(ok "$UNTRUSTED_OK")"
log "Release manifest signed + archived    : $(ok "$ARCHIVE_RC")"
log "Completed (UTC)                       : $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ================================================================ package ===
STUDENT="$STUDENT" scripts/package_submission.sh
