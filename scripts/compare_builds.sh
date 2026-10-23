#!/usr/bin/env bash
# Rebuild-and-compare gate (SSDF PO.3.2 Example 4, PW.6.2).
#
#   scripts/compare_builds.sh DIR_A DIR_B [DIR_C ...]
#
# Each DIR holds the *.tar.gz produced by one independent builder. Every archive
# must exist in every builder's output with the same SHA-256. Exit 0 = all
# identical; exit 1 = drift or tampering (the release must not be signed), and a
# per-file diagnosis is printed. Used both by run_lab.sh and by the CI `compare`
# job. Compatible with bash 3.2.
set -uo pipefail

[ $# -ge 2 ] || { echo "usage: $0 DIR_A DIR_B [DIR_C ...]" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REF_DIR="$1"
status=0

files="$(cd "$REF_DIR" && ls *.tar.gz 2>/dev/null)"
[ -n "$files" ] || { echo "no release archives in $REF_DIR" >&2; exit 2; }

i=0
for d in "$@"; do i=$((i+1)); echo "  B$i = $d"; done
line="$(printf '%-38s' "artifact")"
i=0
for d in "$@"; do i=$((i+1)); line="$line $(printf '%-18s' "B$i sha256")"; done
echo "$line result"
for f in $files; do
  ref="$(shasum -a 256 "$REF_DIR/$f" | cut -c1-64)"
  line="$(printf '%-38s' "$f")"
  verdict="IDENTICAL"
  for d in "$@"; do
    if [ ! -f "$d/$f" ]; then h="(missing)"; verdict="MISMATCH"
    else
      h="$(shasum -a 256 "$d/$f" | cut -c1-64)"
      [ "$h" = "$ref" ] || verdict="MISMATCH"
    fi
    line="$line $(printf '%-18s' "${h:0:16}..")"
  done
  echo "$line $verdict"
  if [ "$verdict" != "IDENTICAL" ]; then
    status=1
    for d in "${@:2}"; do
      if [ -f "$d/$f" ] && [ "$(shasum -a 256 "$d/$f" | cut -c1-64)" != "$ref" ]; then
        echo "  -- diagnosis: $REF_DIR/$f vs $d/$f"
        python3 "$HERE/diagnose_drift.py" "$REF_DIR/$f" "$d/$f" | sed 's/^/     /'
      fi
    done
  fi
done

if [ $status -eq 0 ]; then
  echo "GATE: PASS - all $# builders produced bit-for-bit identical archives"
else
  echo "GATE: FAIL - builders disagree; do NOT sign or publish this release"
fi
exit $status
