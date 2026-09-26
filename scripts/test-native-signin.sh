#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/n2signin.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc tray/NativeSignIn.swift tests/NativeSignInTests.swift -o "$work/test-signin"
"$work/test-signin" "$@"
python3 scripts/test-native-signin-cli.py "$work/test-signin"
