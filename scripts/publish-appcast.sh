#!/bin/zsh
# semantic-release publish: sign the update archive with Sparkle's EdDSA key and
# write this channel's appcast on the `appcasts` branch. Runs after the GitHub
# release exists, so the enclosure URL it records already resolves.
set -euo pipefail
cd "${0:A:h}/.."

version=${1:?usage: publish-appcast.sh <version> <git-tag>}
tag=${2:?git tag required}
channel=${CLAUDES_CHANNEL:?CLAUDES_CHANNEL must be stable or continuous}
: ${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY required}
: ${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}

build=${CLAUDES_BUILD_NUMBER:-${GITHUB_RUN_ID:-0}}
artifact="N2Agents-${channel}-${version}.zip"
[[ -f $artifact ]] || { echo "✗ missing $artifact — prepare did not run" >&2; exit 1 }

key="${RUNNER_TEMP:-$TMPDIR}/sparkle-private-key"
umask 077
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$key"
result=$(.build/artifacts/sparkle/Sparkle/bin/sign_update -f "$key" "$artifact")
rm -f "$key"
signature=${result#*sparkle:edSignature=\"}
signature=${signature%%\"*}
[[ -n $signature ]] || { echo "✗ Sparkle produced no signature" >&2; exit 1 }

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
