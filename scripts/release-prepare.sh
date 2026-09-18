#!/bin/zsh
# semantic-release prepare: build the signed (and, with notary credentials,
# notarized) app for the version semantic-release computed, and leave both
# archives in the checkout for the GitHub release:
#   N2Agents.zip                        — what install.sh resolves
#   N2Agents-<channel>-<version>.zip    — what the appcast enclosure points at
set -euo pipefail
cd "${0:A:h}/.."

version=${1:?usage: release-prepare.sh <version>}
channel=${CLAUDES_CHANNEL:?CLAUDES_CHANNEL must be stable or continuous}
[[ $channel == stable || $channel == continuous ]] || { echo "✗ invalid channel: $channel" >&2; exit 1 }

# CFBundleVersion drives Sparkle's ordering, so it must only ever increase.
build=${CLAUDES_BUILD_NUMBER:-${GITHUB_RUN_ID:-$(date +%s)}}

if [[ -n ${NOTARY_KEY:-} ]]; then
  : ${NOTARY_KEY_ID:?NOTARY_KEY_ID required with NOTARY_KEY}
  : ${NOTARY_KEY_ISSUER:?NOTARY_KEY_ISSUER required with NOTARY_KEY}
  notary="${RUNNER_TEMP:-$TMPDIR}/notary.p8"
  umask 077
  printf '%s' "$NOTARY_KEY" > "$notary"
  NOTARY_KEY_FILE="$notary" ./scripts/release-build.sh "$version" "$build"
else
  echo "::warning::NOTARY_KEY_P8 is not set — publishing signed but un-notarized (install.sh clears quarantine; browser downloads will be blocked by Gatekeeper)"
  ./scripts/release-build.sh "$version" "$build"
fi

codesign --verify --deep --strict --verbose=2 "tray/build/N2 Agents.app"

# Every @rpath dependency must resolve inside the bundle. A missing rpath kills
# the app in dyld before main(), which is how 0.10.1 shipped un-launchable.
binary="tray/build/N2 Agents.app/Contents/MacOS/N2 Agents"
otool -l "$binary" | grep -q '@executable_path/../Frameworks' \
  || { echo "✗ $binary has no @executable_path/../Frameworks rpath" >&2; exit 1 }
for dep in $(otool -L "$binary" | awk '/@rpath\//{print $1}'); do
  [[ -f "tray/build/N2 Agents.app/Contents/Frameworks/${dep#@rpath/}" ]] \
    || { echo "✗ unresolvable dependency: $dep" >&2; exit 1 }
done
if [[ -n ${NOTARY_KEY:-} ]]; then
  xcrun stapler validate "tray/build/N2 Agents.app"
fi

setopt null_glob   # zsh errors on a non-matching glob, even for rm -f
rm -f N2Agents-*-*.zip
unsetopt null_glob
cp N2Agents.zip "N2Agents-${channel}-${version}.zip"
echo "✓ Prepared $version ($channel, build $build)"
