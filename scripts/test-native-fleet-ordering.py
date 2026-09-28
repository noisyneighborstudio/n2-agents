#!/usr/bin/env python3
"""Older fleet reads must not publish after newer success or failure."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'tray/FleetControl.swift').read_text()
method = source[source.index('    func refreshFleet() {'):source.index('    /// The menu bar')]
with tempfile.TemporaryDirectory(prefix='n2-fleet-ordering-') as work:
    work = Path(work)
    fixture = (root / 'tests/FleetReadOrderingTests.swift').read_text()
    swift = work / 'proof.swift'
    swift.write_text(fixture.replace('    // PRODUCTION_METHODS', method))
    executable = work / 'proof'
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                    str(root / 'tray/FleetModel.swift'), str(swift), '-o', str(executable)], check=True)
    for scenario in ('older-success', 'older-failure', 'newer-failure'):
        result = subprocess.run([str(executable), scenario], capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        print(result.stdout.strip())
