#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/n2ownership.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc tray/AccountOwnership.swift tray/FleetSettingsLoader.swift tray/ShellPath.swift tests/AccountOwnershipTests.swift -o "$work/test-ownership"
"$work/test-ownership" "$@"
