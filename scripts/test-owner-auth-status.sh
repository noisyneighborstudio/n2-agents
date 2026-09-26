#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/n2auth-status.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -warnings-as-errors tray/Vendors.swift tests/OwnerAuthStatusTests.swift -o "$work/parse"
python3 scripts/test-owner-auth-status.py "$work/parse" "$@"
