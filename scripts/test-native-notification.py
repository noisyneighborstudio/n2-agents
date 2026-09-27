#!/usr/bin/env python3
"""Exercise the production announcement method without changing OS permissions."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'tray/FleetControl.swift').read_text()
method = source[source.index('    func announce('):source.index('    // MARK: - Enrollment')]
with tempfile.TemporaryDirectory(prefix='n2-notification-') as work:
    work = Path(work)
    swift = work / 'proof.swift'
    swift.write_text((root / 'tests/FleetNotificationTests.swift').read_text().replace('    // PRODUCTION_METHOD', method))
    executable = work / 'proof'
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(root / 'tray/FleetModel.swift'), str(swift), '-o', str(executable)], check=True)
    result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stdout + result.stderr
    print(result.stdout.strip())
