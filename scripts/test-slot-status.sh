#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/n2slotstatus.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
awk '/^struct Profile \{/ {copy=1} copy {print} copy && /^}/ {exit}' tray/main.swift > "$work/Profile.swift"
swiftc -parse-as-library "$work/Profile.swift" tray/PanelModel.swift tray/Vendors.swift tray/StatusIcon.swift \
    tray/FleetModel.swift tray/UpdateChannel.swift tray/Ink.swift tray/StatusInk.swift tray/GlassWindow.swift \
    tests/SlotStatusTests.swift -o "$work/test-slot-status"
"$work/test-slot-status"
