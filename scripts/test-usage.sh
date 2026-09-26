#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/n2usage.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
# Compile the production model without the AppKit-dependent panel types.
awk '/^struct PanelData/ {exit} {print}' tray/PanelModel.swift > "$work/Usage.swift"
swiftc "$work/Usage.swift" tests/UsageTests.swift -o "$work/test-usage"
"$work/test-usage"

python3 scripts/test-codex-rpc.py
python3 scripts/test-codex-run.py
sh scripts/test-bound-agent-run.sh
python3 scripts/test-usage-reader.py

python3 scripts/test-usage-store.py
sh scripts/test-usage-fleet.sh

swiftc loop/UsageAttribution.swift tests/TaskUsageTests.swift -o "$work/test-task-usage"
"$work/test-task-usage"

swiftc loop/SlotMeasurement.swift tests/SlotMeasurementTests.swift -o "$work/test-slot-measurement"
"$work/test-slot-measurement"
