#!/bin/sh
# The same source checks run locally and on every CI push.
set -eu
cd "$(dirname "$0")/.."
case ${1:-} in
  format)
    base=${N2_CHECK_BASE:-HEAD^}
    git diff --check "$base"
    ;;
  lint)
    check_cache=$(mktemp -d)
    trap 'rm -rf "$check_cache"' EXIT HUP INT TERM
    export PYTHONPYCACHEPREFIX="$check_cache"
    python3 -W error - <<'PY'
import py_compile
import subprocess
paths = subprocess.check_output(['git', 'ls-files', '-z', '*.py']).decode().split('\0')
for path in filter(None, paths):
    py_compile.compile(path, doraise=True)
PY
    sh -n agents
    sh -n scripts/check.sh
    sh -n scripts/smoke.sh
    ;;
  *) echo 'usage: scripts/check.sh format|lint' >&2; exit 2 ;;
esac
