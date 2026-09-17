#!/bin/zsh
# CI release build: stamp version, build (signs if a Developer ID identity is
# in the keychain), notarize + staple when notary credentials are present,
# and produce N2Agents.zip for the GitHub release asset.
set -euo pipefail
ver=${1:?usage: release-build.sh <version> [build-version]}
build_ver=${2:-1}
cd "${0:A:h}/.."

N2_VERSION=$ver N2_BUILD_VERSION=$build_ver N2_RELEASE_BUILD=1 ./tray/build.sh

if [[ -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_KEY_ISSUER:-} && -n ${NOTARY_KEY_FILE:-} ]]; then
  echo "Notarizing…"
  ditto -c -k --keepParent tray/build/N2Agents.app N2Agents.zip
  xcrun notarytool submit N2Agents.zip --key "$NOTARY_KEY_FILE" \
    --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_KEY_ISSUER" --wait
  xcrun stapler staple tray/build/N2Agents.app
  rm -f N2Agents.zip
else
  echo "Notary configuration not present — skipping notarization."
fi

ditto -c -k --keepParent tray/build/N2Agents.app N2Agents.zip
echo "Release artifact: N2Agents.zip (v$ver, build $build_ver)"
