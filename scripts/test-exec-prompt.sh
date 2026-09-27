#!/bin/sh
# Actual provider stdin/argv/exit proofs live in the signed-dispatch tests.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2prompt.XXXXXX")
trap 'rm -rf "$base"' EXIT
. "$repo/vendors.sh"
. "$repo/fleet-exec.sh"
export HOME="$base/home" N2_FLEET_TASK=11223344
root="$base/root"
mkdir -p "$base/spec"
for vendor in claude codex; do
  if exec_invoke_prompt "$vendor" "$base/spec" 2>/dev/null; then exit 1; fi
done
echo 'ok prompt providers refuse invocation without an accepted binding'
if exec_invoke_prompt cursor "$base/spec" 2>/dev/null; then exit 1; fi
echo 'ok unsupported provider refuses prompt invocation'
