#!/bin/zsh
# Requires a logged-in macOS desktop. Launches only an isolated fixture app.
# Optional argument is a baseline FleetSyncSettings.swift to compare unchanged.
set -euo pipefail
cd "${0:A:h}/.."
probe_root=$(mktemp -d "${TMPDIR:-/tmp}/n2-settings-probe.XXXXXX")
app="$probe_root/SettingsProbe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$probe_root/cache"
export CLANG_MODULE_CACHE_PATH="$probe_root/cache"
export SWIFT_MODULECACHE_PATH="$probe_root/cache"
cp tests/fixtures/settings-Info.plist "$app/Contents/Info.plist"
cp tests/fixtures/settings-agents "$app/Contents/Resources/agents"
cp tests/fixtures/settings-login-shell "$probe_root/login-shell"
chmod +x "$probe_root/login-shell"
# Match the package's Swift language mode, release optimization and deployment target.
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
  tray/SettingsWindowView.swift "${1:-tray/FleetSyncSettings.swift}" \
  tray/FleetSettingsLoader.swift tray/GlassWindow.swift tray/Ink.swift \
  tray/UpdateChannel.swift tray/ShellPath.swift tests/FleetSettingsUITests.swift \
  -o "$app/Contents/MacOS/SettingsProbe"
echo "Fixture app: $app"
SHELL="$probe_root/login-shell" N2_SETTINGS_TEST_DIR="$probe_root" \
  "$app/Contents/MacOS/SettingsProbe" &
probe_pid=$!
if [[ ${N2_SETTINGS_PROFILE:-0} == 1 ]]; then
  for attempt in {1..100}; do
    [[ -f "$probe_root/peers-started" ]] && break
    sleep 0.05
  done
  /usr/bin/sample "$probe_pid" 1 1 -file "$probe_root/stack-sample.txt"
fi
wait "$probe_pid"
