#!/bin/zsh
# semantic-release publish: sign the update archive with Sparkle's EdDSA key and
# write this channel's appcast on the `appcasts` branch. Runs after the GitHub
# release exists, so the enclosure URL it records already resolves.
set -euo pipefail
cd "${0:A:h}/.."

version=${1:?usage: publish-appcast.sh <version> <git-tag>}
tag=${2:?git tag required}
channel=${N2_CHANNEL:?N2_CHANNEL must be stable or continuous}
build=${N2_BUILD_NUMBER:?N2_BUILD_NUMBER required}
: ${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY required}
: ${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}

artifact="N2Agents-${channel}-${version}.zip"
[[ -f $artifact ]] || { echo "✗ missing $artifact — prepare did not run" >&2; exit 1 }

# Key via stdin: never on disk, never in argv.
signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | .build/artifacts/sparkle/Sparkle/bin/sign_update -f - -p "$artifact")
# A key that doesn't match the app's SUPublicEDKey makes every client reject
# the update — check it the way the app will, before anything is published.
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "tray/build/N2 Agents.app/Contents/Info.plist")
swift scripts/verify-signature.swift "$public_key" "$signature" "$artifact" \
  || { echo "✗ SPARKLE_PRIVATE_KEY does not match SUPublicEDKey in tray/Info.plist" >&2; exit 1 }

url="https://github.com/${GITHUB_REPOSITORY}/releases/download/${tag}/${artifact}"
publication="${RUNNER_TEMP:-$TMPDIR}/appcasts"
rm -rf "$publication"
if git ls-remote --exit-code --heads origin appcasts >/dev/null; then
  git worktree add "$publication" origin/appcasts
else
  git worktree add --detach "$publication" HEAD
  git -C "$publication" checkout --orphan appcasts
  git -C "$publication" rm -rf .
fi
./scripts/make-appcast.sh "$channel" "$version" "$build" "$url" "$artifact" "$signature" "$publication/$channel/appcast.xml"
git -C "$publication" add -- "$channel/appcast.xml"
git -C "$publication" config user.name github-actions
git -C "$publication" config user.email github-actions@github.com
git -C "$publication" commit -m "Publish $channel $version"
git -C "$publication" push origin HEAD:appcasts
git worktree remove --force "$publication"
echo "✓ Published $channel appcast for $version"
