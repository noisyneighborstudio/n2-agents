#!/bin/sh
# Real managed installer commands in an isolated HOME, no provider login.
set -u
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2prepare.XXXXXX")
trap 'rm -rf "$base"' EXIT
export HOME="$base/home"
mkdir -p "$HOME"
"$repo/agents" fleet init --machine preparation-test >/dev/null || exit 1
. "$repo/fleet.sh"
. "$repo/fleet-sync.sh"
. "$repo/fleet-exec.sh"
check() { "$@" || { echo "FAIL: $*"; exit 1; }; }
reject() { if "$@"; then echo "FAIL: unexpectedly accepted $*"; exit 1; fi; }
printf 'widget\n' > "$base/requires"
check cmd_fleet_tools add widget --version 1 --check 'cat "$HOME/version" 2>/dev/null' --install 'printf 1 > "$HOME/version"'
check exec_prepare_requirements "$base/requires"
check test "$(cat "$HOME/version")" = 1
echo 'ok missing managed requirement installed'
mkdir -p "$(sync_tasks_dir)"
printf 'task busy\n' > "$(sync_tasks_dir)/busy"
check cmd_fleet_tools add widget --version 2 --check 'cat "$HOME/version" 2>/dev/null' --install 'printf 2 > "$HOME/version"' --disruptive
reject exec_prepare_requirements "$base/requires"
check test "$(cat "$HOME/version")" = 1
echo 'ok disruptive preparation deferred during active work'
rm "$(sync_tasks_dir)/busy"
check exec_prepare_requirements "$base/requires"
check test "$(cat "$HOME/version")" = 2
echo 'ok deferred requirement installs after work ends'
check cmd_fleet_tools add widget --version 3 --check 'cat "$HOME/version" 2>/dev/null' --install 'exit 1'
reject exec_prepare_requirements "$base/requires"
echo 'ok installer failure prevents preparation success'
printf 'n2-nonexistent-unmanaged-tool\n' > "$base/requires"
reject exec_prepare_requirements "$base/requires"
printf 'sh\n' > "$base/requires"
check exec_prepare_requirements "$base/requires"
echo 'ok unmanaged tools require an existing executable'
printf 'widget;touch evil\n' > "$base/requires"
reject exec_prepare_requirements "$base/requires"
echo 'ok malformed requirements rejected'
exec_bundle_build "$base/bundle" task '' '' "$base/requires" > "$base/task.tar"
check tar -xf "$base/task.tar" -C "$base"
check cmp "$base/requires" "$base/spec/requires"
echo 'ok requirements included in transferred bundle'
