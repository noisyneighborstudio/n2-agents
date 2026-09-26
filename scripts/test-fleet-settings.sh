#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc tray/FleetSettingsLoader.swift tray/ShellPath.swift tests/FleetSettingsLoaderTests.swift -o "$work/proof"
LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 "$work/proof"
