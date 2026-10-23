#!/usr/bin/env bash
# Package the Week 7 deliverables into [Student]_SSDF_Week7.zip.
# Called at the end of run_lab.sh; can be re-run on its own after editing
# build_drift_findings.md. Compatible with bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/.."

STUDENT="${STUDENT:-ShuchenMeng}"
ZIP="${STUDENT}_SSDF_Week7.zip"
for f in verification_log.txt cosign.pub release/SHA256SUMS release/SHA256SUMS.sigstore.json \
         release/release-manifest.json release/release-manifest.json.sigstore.json release/sbom.cyclonedx.json; do
  [ -f "$f" ] || { echo "missing $f - run ./run_lab.sh first" >&2; exit 1; }
done

TMP="$(mktemp -d)"
STAGE="$TMP/${STUDENT}_SSDF_Week7"
mkdir -p "$STAGE/supporting/evidence" "$STAGE/supporting/.github"
# deliverables
cp .github/workflows/reproducible_release.yml Makefile build_drift_findings.md verification_log.txt cosign.pub "$STAGE/"
cp release/SHA256SUMS release/SHA256SUMS.sigstore.json release/release-manifest.json \
   release/release-manifest.json.sigstore.json release/sbom.cyclonedx.json "$STAGE/"
# everything needed to rebuild and re-run the lab
cp -R cmd internal tools scripts reference vendor go.mod go.sum README.md LICENSE run_lab.sh "$STAGE/supporting/"
cp .github/dependabot.yml "$STAGE/supporting/.github/"
cp evidence/*.txt "$STAGE/supporting/evidence/" 2>/dev/null || true
find "$STAGE" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

rm -f "$ZIP"
( cd "$TMP" && zip -qrX "$OLDPWD/$ZIP" "$(basename "$STAGE")" )
rm -rf "$TMP"
echo "打包完成: $(pwd)/${ZIP}"
unzip -l "$ZIP" | grep -v '/supporting/vendor/'
