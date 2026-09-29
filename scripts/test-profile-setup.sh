#!/bin/sh
# Shared first-use/reset setup against a fake host; no real credentials or windows.
set -eu
cd "$(dirname "$0")/.."
setup_root=$(mktemp -d)
trap 'rm -rf "$setup_root"' EXIT HUP INT TERM
swiftc tests/ProfileSetupTests.swift tray/NativeAuth.swift tray/Vendors.swift tray/Ink.swift tray/LabMark.swift \
  tray/ProfileSetup.swift tray/GlassWindow.swift tray/Motion.swift -o "$setup_root/profile-setup-tests"
"$setup_root/profile-setup-tests"
