#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/n2panelusage.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
# Extract only the production profile type; the app delegate starts the real UI.
awk '/^struct Profile \{/ {copy=1} copy {print} copy && /^}/ {exit}' tray/main.swift > "$work/Profile.swift"
swiftc "$work/Profile.swift" tray/PanelModel.swift tray/Vendors.swift tray/StatusIcon.swift \
    tray/FleetModel.swift tray/UpdateChannel.swift tests/PanelUsageTests.swift -o "$work/test-panel-usage"
"$work/test-panel-usage"
