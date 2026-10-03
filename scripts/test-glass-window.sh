#!/bin/sh
# The glass window keeps its content pinned to the top while it resizes.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp tests/GlassWindowTests.swift "$work/main.swift"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  tray/GlassWindow.swift tray/Motion.swift tray/Ink.swift "$work/main.swift" -o "$work/proof"
"$work/proof"
