#!/bin/sh
# Optional GUI proof; capture only a synthetic alert, never live account state.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/n2signin-preview.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
swiftc -warnings-as-errors tray/NativeSignIn.swift tests/NativeSignInPreview.swift -o "$work/preview"
python3 - "$work/preview" "${1:?PNG destination required}" <<'PY'
import select, subprocess, sys
process = subprocess.Popen([sys.argv[1]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    assert select.select([process.stdout], [], [], 10)[0], 'window update timed out'
    line = process.stdout.readline()
    assert line.startswith('READY '), line
    subprocess.run(['/usr/sbin/screencapture', '-x', '-l', line.split()[1], sys.argv[2]], check=True, timeout=10)
finally:
    process.terminate(); process.wait(timeout=5)
    process.stdout.close(); process.stderr.close()
PY
