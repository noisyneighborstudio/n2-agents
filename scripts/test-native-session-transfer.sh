#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/n2transfer.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -warnings-as-errors tray/NativeSignIn.swift tray/NativeSessionTransfer.swift tray/FleetModel.swift tests/NativeSessionTransferTests.swift -o "$work/test-transfer"
"$work/test-transfer"
python3 scripts/test-native-session-transfer-cli.py "$work/test-transfer"
