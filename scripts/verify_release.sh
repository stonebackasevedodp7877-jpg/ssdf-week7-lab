#!/usr/bin/env bash
# Consumer-side release verification (SSDF PS.2.1).
#
#   scripts/verify_release.sh RELEASE_DIR --key cosign.pub
#   scripts/verify_release.sh RELEASE_DIR --identity URI --issuer URL   (CI keyless)
#
# 1. The signature on SHA256SUMS must verify against the TRUSTED key / identity
#    -> proves the hash list came from the release signer.
# 2. Every file listed in SHA256SUMS must match its hash
#    -> proves the downloaded files are the ones that were signed.
# A hash proves the file matches the list; only the signature proves the list.
# Exit 0 only if both checks pass. Compatible with bash 3.2.
set -uo pipefail

DIR="${1:?usage: $0 RELEASE_DIR (--key PUB | --identity URI --issuer URL)}"; shift
LIST="$DIR/SHA256SUMS"
BUNDLE="$DIR/SHA256SUMS.sigstore.json"
[ -f "$LIST" ] && [ -f "$BUNDLE" ] || { echo "missing $LIST or $BUNDLE" >&2; exit 2; }

ARGS=()
case "${1:-}" in
  --key)      ARGS=(--key "$2") ;;
  --identity) ARGS=(--certificate-identity "$2" --certificate-oidc-issuer "$4") ;;
  *) echo "need --key or --identity/--issuer" >&2; exit 2 ;;
esac
# A bundle signed offline (no Rekor entry) carries no tlogEntries; cosign then
# needs an explicit opt-out of the transparency-log check.
if ! grep -q '"tlogEntries"' "$BUNDLE"; then
  ARGS+=(--insecure-ignore-tlog=true)
  echo "note: bundle has no transparency-log entry (signed offline); verifying signature only"
fi

echo "[1/2] cosign verify-blob SHA256SUMS"
if ! cosign verify-blob "${ARGS[@]}" --bundle "$BUNDLE" "$LIST" 2>&1; then
  echo "RESULT: REJECTED - signature on SHA256SUMS is not valid for the trusted signer"
  exit 1
fi

echo "[2/2] shasum -a 256 -c SHA256SUMS"
if ! ( cd "$DIR" && LC_ALL=C shasum -a 256 -c SHA256SUMS ) 2>&1; then
  echo "RESULT: REJECTED - a release file does not match the signed hash list"
  exit 1
fi
echo "RESULT: VERIFIED - signed hash list and all release files check out"
