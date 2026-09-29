#!/usr/bin/env python3
"""Exercise production fleet publication and stale dispatch admission offline."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'tray/FleetControl.swift').read_text()
refresh = source[source.index('    func refreshFleet() {'):source.index('    /// The menu bar')]
start = source.index('    func fleetDispatch(_ spec: FleetDispatchSpec) {')
dispatch = source[start:source.index('        model.workDraft.state = .sending', start)]
dispatch += '        fatalError("stale dispatch passed admission")\n    }\n'
start = source.index('    func fleetRetry(task: String) {')
retry = source[start:source.index('        let confirm = NSAlert()', start)]
retry += '        fatalError("stale retry passed admission")\n    }\n'
with tempfile.TemporaryDirectory(prefix='n2-fleet-read-') as work:
    work = Path(work)
    fixture = (root / 'tests/FleetReadTests.swift').read_text()
    swift = work / 'proof.swift'
    swift.write_text(fixture.replace('    // PRODUCTION_METHODS', refresh + dispatch + retry))
    executable = work / 'proof'
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                    str(root / 'tray/FleetModel.swift'), str(swift), '-o', str(executable)], check=True)
    result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stdout + result.stderr
    print(result.stdout.strip())
