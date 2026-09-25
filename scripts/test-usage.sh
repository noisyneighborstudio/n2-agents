#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/n2usage.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
# Compile the production model without the AppKit-dependent panel types.
awk '/^struct PanelData/ {exit} {print}' tray/PanelModel.swift > "$work/Usage.swift"
swiftc "$work/Usage.swift" tests/UsageTests.swift -o "$work/test-usage"
"$work/test-usage"

python3 scripts/test-usage-reader.py

python3 scripts/test-usage-store.py
sh scripts/test-usage-fleet.sh
