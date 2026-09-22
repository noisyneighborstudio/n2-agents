#!/bin/zsh
# Builds "tray/build/N2 Agents.app" with the CLI + adapter table embedded in
# Resources. The bundle, its name and its executable are all "N2 Agents", so
# Finder, Activity Monitor and Login Items agree — every path is quoted.
# Release zips keep the space-free N2Agents name: they end up in URLs.
# Signing: uses a "Developer ID Application" identity if one is in the keychain
# (override with N2_SIGN_IDENTITY), otherwise falls back to ad-hoc.
set -euo pipefail
cd "${0:A:h}"

command -v swift >/dev/null || { echo "✗ swift not found. Install Xcode Command Line Tools: xcode-select --install" >&2; exit 1 }

app="build/N2 Agents.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"

echo "Compiling…"
swift build --package-path .. -c release --product N2AgentsTray
bin_dir=$(swift build --package-path .. -c release --show-bin-path)
cp "$bin_dir/N2AgentsTray" "$app/Contents/MacOS/N2 Agents"
sparkle_framework=$(find ../.build -type d -name Sparkle.framework -print -quit)
[[ -n $sparkle_framework ]] || { echo "✗ Sparkle.framework was not produced" >&2; exit 1; }
ditto "$sparkle_framework" "$app/Contents/Frameworks/Sparkle.framework"
swiftc -O icon-badge/main.swift ProfileColor.swift -o "$app/Contents/Resources/icon-badge"
cp Info.plist "$app/Contents/"

# Version: explicit N2_VERSION (CI) > latest git tag (source builds) > 0.0.0.
# Sparkle uses these values when comparing entries in the selected appcast.
ver=${N2_VERSION:-$(git -C .. describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}
ver=${ver:-0.0.0}
build_ver=${N2_BUILD_VERSION:-1}
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ver" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_ver" "$app/Contents/Info.plist"
# SUPublicEDKey is committed in Info.plist, so source and release builds trust
# the same key; N2_SPARKLE_PUBLIC_KEY overrides it for testing a throwaway key.
if [[ -n ${N2_SPARKLE_PUBLIC_KEY:-} ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $N2_SPARKLE_PUBLIC_KEY" "$app/Contents/Info.plist"
fi
# Feed URLs come from updates.env, the one place update hosting is configured.
source ../updates.env
for channel key in stable N2AgentsStableFeedURL continuous N2AgentsContinuousFeedURL; do
  /usr/libexec/PlistBuddy -c "Add :$key string $N2_FEED_BASE_URL/$channel/appcast.xml" "$app/Contents/Info.plist"
done
echo "Version: $ver ($build_ver)"
cp ../make-claude-profile.sh ../repatch-claude-profiles.sh ../agents ../vendors.sh ../fleet.sh ../fleet-sync.sh "$app/Contents/Resources/"
cp ../shell/agents.zsh ../shell/agents.bash ../shell/agents.fish ../shell/agent-as "$app/Contents/Resources/"
chmod +x "$app/Contents/Resources/"*.sh "$app/Contents/Resources/agents" "$app/Contents/Resources/agent-as"

# App icon: build multi-res icns from n2agents.png
iconset=$(mktemp -d)/n2agents.iconset
mkdir -p "$iconset"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz n2agents.png --out "$iconset/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) n2agents.png --out "$iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/n2agents.icns"
rm -rf "${iconset:h}"

identity=${N2_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}
if [[ -n ${identity:-} ]]; then
  echo "Signing with: $identity"
  sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
  for nested in \
    "$sparkle/XPCServices/Downloader.xpc" \
    "$sparkle/XPCServices/Installer.xpc" \
    "$sparkle/Autoupdate" \
    "$sparkle/Updater.app" \
    "$app/Contents/Frameworks/Sparkle.framework" \
    "$app/Contents/Resources/icon-badge"
  do
    codesign --force --timestamp --options runtime --sign "$identity" "$nested"
  done
  codesign --force --timestamp --options runtime --entitlements entitlements.plist --sign "$identity" "$app"
else
  echo "No Developer ID identity found — signing ad-hoc (fine for local use)."
  codesign --force -s - "$app/Contents/Frameworks/Sparkle.framework"
  codesign --force -s - "$app/Contents/Resources/icon-badge"
  codesign --force -s - "$app"
fi
codesign -v "$app"

echo "Built $app"
echo "Install:  cp -R $app /Applications/  (then open it, optionally add to Login Items)"
