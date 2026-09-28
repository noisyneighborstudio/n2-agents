#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/n2boundrun.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc loop/Model.swift loop/Store.swift loop/Support.swift loop/Slots.swift loop/SlotMeasurement.swift loop/UsageAttribution.swift loop/AgentRun.swift tests/BoundAgentRunTests.swift -o "$work/test-bound-run"
"$work/test-bound-run" "$PWD"
