#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
# Compile actual model and profile definitions without launching the app.
printf 'import SwiftUI\n' > "$fixture/PanelModel.swift"
cat tray/PanelModel.swift >> "$fixture/PanelModel.swift"
sed -n '/^struct Profile {/,/^}/p' tray/main.swift > "$fixture/Profile.swift"
swiftc "$fixture/PanelModel.swift" "$fixture/Profile.swift" tray/Vendors.swift tray/StatusIcon.swift tray/UpdateChannel.swift tests/UsageTests.swift -o "$fixture/test-usage"
"$fixture/test-usage"
