#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
case ${1:-} in
  format) git diff --check "${N2_CHECK_BASE:-HEAD^}" ;;
  lint)
    sh -n agents
    for script in scripts/check.sh scripts/verify.sh scripts/smoke.sh; do sh -n "$script"; done
    python3 -W error - <<'PYTHON'
import subprocess
from pathlib import Path
for path in subprocess.check_output(['git', 'ls-files', '*.py'], text=True).splitlines():
    compile(Path(path).read_text(), path, 'exec')
PYTHON
    ;;
  *) echo 'usage: scripts/check.sh format|lint' >&2; exit 2 ;;
esac
