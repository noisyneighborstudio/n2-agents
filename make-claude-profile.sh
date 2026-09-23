#!/bin/zsh
# make-claude-profile.sh <Name> — clone Claude.app into an isolated profile instance.
# Creates /Applications/Claude-<Name>.app with its own bundle id, dock icon,
# login state (--user-data-dir baked in), plus the profile's Claude Code slot.
# This is the one vendor with a desktop app worth cloning; every other lab in
# the adapter table is CLI-only, so `agents new` handles those with a mkdir.
set -euo pipefail

die() { echo "✗ $1" >&2; exit 1 }

name=${1:?usage: make-claude-profile.sh <Name>   (letters/numbers only, e.g. Work)}
[[ $name =~ ^[A-Za-z0-9]+$ ]] || die "Profile name must be letters/numbers only, got: $name"
[[ ${name:l} != as && ${name:l} != default ]] || die "Profile name is reserved: $name"

# The bundle can live outside /Applications (per-user install, or a path the
# tray was pointed at) — the agents CLI owns that lookup.
src=$("${0:A:h}/agents" app-path 2>/dev/null) || \
  die "Claude Desktop is not installed. Get it from https://claude.ai/download, or create a Claude Code-only profile: agents new $name --vendors claude --cli-only"
dst="/Applications/Claude-$name.app"
data="$HOME/Library/Application Support/Claude-$name"
cfg="$HOME/.n2-agents/$name/claude"

[[ -f $src/Contents/Info.plist ]] || die "$src looks damaged (no Info.plist). Reinstall Claude Desktop."
[[ -d $dst ]] && die "$dst already exists. Delete that profile first (N2 Agents menu → Delete Profile) or pick another name."
[[ -w /Applications ]] || die "No write permission for /Applications. Run from an admin account."

# Enough disk for the clone (+512MB headroom)?
need_kb=$(du -sk "$src" | awk '{print $1}')
avail_kb=$(df -k /Applications | tail -1 | awk '{print $4}')
(( avail_kb > need_kb + 524288 )) || die "Not enough free disk space: need ~$(( (need_kb + 524288) / 1048576 ))GB free, have $(( avail_kb / 1048576 ))GB."

# From here on, remove a half-built clone if anything fails.
cleanup() { echo "✗ Failed — removing partial clone." >&2; rm -rf "$dst" }
trap cleanup ERR INT TERM

echo "Cloning Claude.app -> Claude-$name.app (this copies the whole bundle)…"
cp -R "$src" "$dst"

# Never inherit a quarantine flag — locally-created bundles shouldn't fight Gatekeeper.
xattr -dr com.apple.quarantine "$dst" 2>/dev/null || true

plist="$dst/Contents/Info.plist"
pb() {
  /usr/libexec/PlistBuddy -c "Set $1 $2" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add $1 string $2" "$plist"
}

# Distinct bundle id + display name => separate identity/notifications.
# CFBundleName must stay "Claude": Electron derives the helper-app path from it
# ("<CFBundleName> Helper.app") and aborts with "Unable to find helper app" if changed.
pb ":CFBundleIdentifier"  "com.anthropic.claudefordesktop.${name:l}"
pb ":CFBundleDisplayName" "Claude $name"

# Badge the icon: colored ribbon with the profile name, so Dock/Cmd-Tab icons
# are distinguishable. Best-effort — a profile without a badge still works.
badge="${0:A:h}/icon-badge"
[[ -x $badge ]] || badge="${0:A:h}/tray/build/N2 Agents.app/Contents/Resources/icon-badge"  # dev-tree fallback
iconfile=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$plist" 2>/dev/null || echo electron)
iconfile="${iconfile%.icns}.icns"
if [[ -x $badge && -f "$dst/Contents/Resources/$iconfile" ]]; then
  echo "Badging icon…"
  tmpd=$(mktemp -d)
  if "$badge" "$dst/Contents/Resources/$iconfile" "$tmpd/badged.png" "$name" 2>/dev/null; then
    mkdir "$tmpd/icon.iconset"
    for sz in 16 32 128 256 512; do
      sips -z $sz $sz "$tmpd/badged.png" --out "$tmpd/icon.iconset/icon_${sz}x${sz}.png" >/dev/null 2>&1
      sips -z $((sz*2)) $((sz*2)) "$tmpd/badged.png" --out "$tmpd/icon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$tmpd/icon.iconset" -o "$dst/Contents/Resources/$iconfile" 2>/dev/null \
      || echo "  (icon badge skipped — iconutil failed)"
  else
    echo "  (icon badge skipped)"
  fi
  rm -rf "$tmpd"
fi

# Wrap the real binary so the isolated data dir applies on every launch,
# including plain double-click from Finder/Dock.
exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist")
cd "$dst/Contents/MacOS"
if [[ ! -f "$exe-bin" ]]; then
  mv "$exe" "$exe-bin"
fi
cat > "$exe" <<EOF
#!/bin/zsh
exec "\${0:A:h}/$exe-bin" --user-data-dir="$data" "\$@"
EOF
chmod +x "$exe"

# Signing. Two rules learned the hard way:
#  - Never --deep: it strips Electron's entitlements (allow-jit etc.) from the
#    inner binaries -> instant SIGTRAP in ElectronMain.
#  - The main binary's ORIGINAL signature seals the bundle's Info.plist, which
#    we just edited -> re-sign Claude-bin ad-hoc, carrying over its entitlements
#    minus the team-provisioned ones an ad-hoc signature can't hold.
echo "Re-signing main binary (ad-hoc, entitlements preserved)…"
ent=$(mktemp -t claude-ent).plist
codesign -d --entitlements - --xml "$src" > "$ent" 2>/dev/null
for key in "com.apple.application-identifier" "com.apple.developer.team-identifier" "keychain-access-groups"; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$ent" 2>/dev/null || true
done
# Ad-hoc (team-less) binary must be allowed to load Anthropic's team-signed
# Electron Framework, or dyld aborts at launch with "different Team IDs".
/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ent"
codesign --force -s - --options runtime --entitlements "$ent" "$dst/Contents/MacOS/$exe-bin"
rm -f "$ent"

# Helpers/frameworks keep Anthropic's original valid signatures untouched.
echo "Re-sealing outer bundle (ad-hoc)…"
codesign --force -s - "$dst"
codesign -v "$dst" || die "Signature verification failed — please file an issue with the output above."

trap - ERR INT TERM
mkdir -p "$data" "$cfg"

echo ""
echo "✓ Profile '$name' ready."
echo "  Desktop:  open -a 'Claude-$name'   (sign in on first launch; a keychain prompt on first login is normal — allow it)"
echo "  CLI:      claude-${name:l}   (or CLAUDE_CONFIG_DIR=$cfg claude; run /login once)"
