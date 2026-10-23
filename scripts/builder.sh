#!/usr/bin/env bash
# One independent, isolated build of a commit - used by run_lab.sh to play the
# role of a separate CI runner / third-party rebuilder (SSDF PO.3.2, PO.5.1).
#
#   scripts/builder.sh NAME SOURCE_REPO REF WORKDIR [MAKEFILE]
#
# Each builder gets its own fresh checkout in its own directory and its own
# empty Go build cache. Knobs that a reproducible build must be immune to:
#   BUILDER_TZ      time zone            (default UTC)
#   BUILDER_UMASK   file-creation mask   (default 022)
#   BUILDER_LANG    locale               (default C)
#   EXPORT_ONLY=1   build from `git archive` output: no .git directory, so the
#                   commit and SOURCE_DATE_EPOCH are passed in explicitly
#                   (an outside party rebuilding from a source tarball)
#   TAMPER=1        simulate a compromised builder that slips an extra file
#                   into the tree after checkout (SolarWinds/SUNSPOT pattern)
#   MAKE_ARGS       extra make arguments (used by the "each fix is necessary" test)
#
# Prints "sha256  file" for every release archive and writes WORKDIR/SHA256SUMS.
# Compatible with bash 3.2 (macOS) and bash 5 (Linux).
set -euo pipefail

NAME="$1"; SRC="$2"; REF="$3"; WORK="$4"; MK="${5:-Makefile}"

rm -rf "$WORK"; mkdir -p "$WORK"
CHECKOUT="$WORK/src/healthsync"

if [ "${EXPORT_ONLY:-0}" = "1" ]; then
  mkdir -p "$CHECKOUT"
  COMMIT_SHA="$(git -C "$SRC" rev-parse "${REF}^{commit}")"
  EPOCH="$(git -C "$SRC" log -1 --format=%ct "$COMMIT_SHA")"
  git -C "$SRC" archive --format=tar "$COMMIT_SHA" | tar -xf - -C "$CHECKOUT"
  export COMMIT="$COMMIT_SHA" SOURCE_DATE_EPOCH="$EPOCH"
else
  git clone --quiet --no-hardlinks "$SRC" "$CHECKOUT"
  git -C "$CHECKOUT" -c advice.detachedHead=false checkout --quiet "$REF"
fi

if [ "${TAMPER:-0}" = "1" ]; then
  # Inert lab fixture standing in for an implant: it registers an extra HTTP
  # route that is not in the reviewed source. The point is only that the
  # shipped bytes no longer match what an honest builder produces.
  cat > "$CHECKOUT/cmd/healthsync/zz_build_implant.go" <<'GO'
package main

import "net/http"

// Injected by a compromised build host, not present in the reviewed commit.
func init() {
	http.HandleFunc("/debug/export", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
}
GO
fi

export GOCACHE="$WORK/gocache"        # empty build cache: nothing reused
export TZ="${BUILDER_TZ:-UTC}"
export LANG="${BUILDER_LANG:-C}"
umask "${BUILDER_UMASK:-022}"

(
  cd "$CHECKOUT"
  # shellcheck disable=SC2086
  make -s -f "$MK" release DIST="$WORK/out" ${MAKE_ARGS:-} >"$WORK/build.log" 2>&1
) || { echo "builder ${NAME}: build FAILED (see $WORK/build.log)" >&2; tail -20 "$WORK/build.log" >&2; exit 1; }

( cd "$WORK/out" && LC_ALL=C LANG=C shasum -a 256 *.tar.gz > "$WORK/SHA256SUMS" )
sed "s/^/builder ${NAME}: /" "$WORK/SHA256SUMS"
