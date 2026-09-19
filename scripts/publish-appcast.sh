#!/bin/zsh
# semantic-release publish: sign the update archive with Sparkle's EdDSA key,
# upload the archives to a release on $N2_UPDATES_REPO, then write this
# channel's appcast on that repo's `appcasts` branch — archives first, so the
# enclosure URL resolves before any client can read it. Hosting: updates.env.
set -euo pipefail
cd "${0:A:h}/.."

version=${1:?usage: publish-appcast.sh <version> <git-tag>}
tag=${2:?git tag required}
channel=${N2_CHANNEL:?N2_CHANNEL must be stable or continuous}
build=${N2_BUILD_NUMBER:?N2_BUILD_NUMBER required}
: ${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY required}
export GH_TOKEN=${N2_UPDATES_TOKEN:?N2_UPDATES_TOKEN required (write access to the updates repo)}
source ./updates.env

artifact="N2Agents-${channel}-${version}.zip"
[[ -f $artifact ]] || { echo "✗ missing $artifact — prepare did not run" >&2; exit 1 }

# Key via stdin: never on disk, never in argv.
signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | .build/artifacts/sparkle/Sparkle/bin/sign_update -f - -p "$artifact")
# A key that doesn't match the app's SUPublicEDKey makes every client reject
# the update — check it the way the app will, before anything is published.
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "tray/build/N2 Agents.app/Contents/Info.plist")
swift scripts/verify-signature.swift "$public_key" "$signature" "$artifact" \
  || { echo "✗ SPARKLE_PRIVATE_KEY does not match SUPublicEDKey in tray/Info.plist" >&2; exit 1 }

# semantic-release has already created this release when the updates repo is
# this repo; otherwise it's created here. Continuous stays a prerelease so
# releases/latest (what install.sh resolves) is always stable.
if ! gh release view "$tag" -R "$N2_UPDATES_REPO" >/dev/null 2>&1; then
  kind=(--latest); [[ $channel == continuous ]] && kind=(--prerelease)
  gh release create "$tag" -R "$N2_UPDATES_REPO" $kind --title "N2 Agents $version" --notes "N2 Agents $version ($channel)"
fi
gh release upload "$tag" -R "$N2_UPDATES_REPO" --clobber N2Agents.zip "$artifact"
url="https://github.com/${N2_UPDATES_REPO}/releases/download/${tag}/${artifact}"

# Token as a header from the environment: out of argv, out of .git/config.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64)"
remote="https://github.com/${N2_UPDATES_REPO}.git"
publication=$(mktemp -d)
if [[ -n $(git ls-remote --heads "$remote" appcasts) ]]; then
  git clone --quiet --depth 1 --branch appcasts "$remote" "$publication"
else
  git init --quiet -b appcasts "$publication"
fi
./scripts/make-appcast.sh "$channel" "$version" "$build" "$url" "$artifact" "$signature" "$publication/$channel/appcast.xml"
git -C "$publication" add -- "$channel/appcast.xml"
git -C "$publication" -c user.name=github-actions -c user.email=github-actions@github.com \
  commit --quiet -m "Publish $channel $version"
git -C "$publication" push --quiet "$remote" HEAD:appcasts
rm -rf "$publication"
echo "✓ Published $channel appcast for $version → $N2_FEED_BASE_URL/$channel/appcast.xml"

# The installer people curl lives beside the builds, and follows stable.
if [[ $channel == stable ]]; then
  sha=$(gh api "repos/$N2_UPDATES_REPO/contents/install.sh" --jq .sha 2>/dev/null || true)
  gh api -X PUT "repos/$N2_UPDATES_REPO/contents/install.sh" \
    -f message="install.sh for $version" -f content="$(base64 < install.sh)" ${sha:+-f sha="$sha"} >/dev/null
  echo "✓ install.sh published with $version"
fi
