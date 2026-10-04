#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
/usr/bin/python3 scripts/test-busybar.py
work=$(mktemp -d "${TMPDIR:-/tmp}/n2busybar.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
awk '/^struct Profile \{/ {copy=1} copy {print} copy && /^}/ {exit}' tray/main.swift > "$work/Profile.swift"
swiftc -parse-as-library "$work/Profile.swift" tray/PanelModel.swift tray/Vendors.swift tray/StatusIcon.swift \
    tray/FleetModel.swift tray/UpdateChannel.swift tray/Ink.swift tray/StatusInk.swift tray/UsageTiers.swift tray/PanelMenus.swift tray/LabMark.swift tray/GlassWindow.swift tray/Motion.swift \
    tray/BusyBar.swift tray/BusyBarSettings.swift tray/FleetSettingsLoader.swift tray/ShellPath.swift \
    tests/BusyBarTests.swift -o "$work/test-busybar"
"$work/test-busybar"
