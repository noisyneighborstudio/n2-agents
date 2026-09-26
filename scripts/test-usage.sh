#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/n2usage.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
# Compile the production model without the AppKit-dependent panel types.
awk '/^struct PanelData/ {exit} {print}' tray/PanelModel.swift > "$work/Usage.swift"
swiftc "$work/Usage.swift" tests/UsageTests.swift -o "$work/test-usage"
python3 - "$work/claude-current.jsonl" <<'PYCLAUDE'
import importlib.util,json,sys
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('usage','usage.py');u=importlib.util.module_from_spec(spec);spec.loader.exec_module(u)
data=json.load(open('tests/fixtures/claude-usage-current.json'))
with open(sys.argv[1],'w') as output, patch.object(u.sys,'stdout',output):
    for name,percent in [('Available',0),('ModelLimited',100)]:
        data['limits'][2]['percent']=percent
        with patch.dict(u.os.environ,{'N2_USAGE_FORMAT':'json'},clear=True), patch.object(u.sys,'argv',['usage.py','claude',name+'=/fixture']), patch.object(u,'claude',return_value=('ok',lambda:data)):
            u.main()
PYCLAUDE
"$work/test-usage" "$work/claude-current.jsonl"

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
