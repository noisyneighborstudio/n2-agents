#!/bin/sh
# Also used by publication: a failed gate must stop before credentials or release.
set -eu
cd "$(dirname "$0")/.."
scripts/check.sh format
scripts/check.sh lint
zsh scripts/test.sh
scripts/smoke.sh
