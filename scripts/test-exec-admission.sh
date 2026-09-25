#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2admission.XXXXXX")
trap 'rm -rf "$base"' EXIT
export HOME="$base/home"
mkdir -p "$HOME"
"$repo/agents" fleet init --machine admission >/dev/null
. "$repo/fleet.sh"
. "$repo/fleet-sync.sh"
. "$repo/fleet-exec.sh"
cmd_fleet_tools add prerequisite --version 1 --check 'cat "$HOME/prepared" 2>/dev/null' --install 'touch "$HOME/preparing"; while [ ! -f "$HOME/release" ]; do sleep 0.05; done; printf 1 > "$HOME/prepared"' >/dev/null
cmd_fleet_tools add disruptive --version 1 --check 'cat "$HOME/disrupted" 2>/dev/null' --install 'printf 1 > "$HOME/disrupted"' --disruptive >/dev/null
printf 'prerequisite\n' > "$base/requires"
exec_prepare_requirements "$base/requires" abcd1234 &
prepare_pid=$!
for attempt in $(seq 1 100); do [ -f "$HOME/preparing" ] && break; sleep 0.05; done
[ -f "$HOME/preparing" ]
( cmd_fleet_tools install disruptive > "$base/installer-result" ) &
installer_pid=$!
sleep 0.1
[ ! -f "$HOME/disrupted" ]
touch "$HOME/release"
wait "$prepare_pid"
wait "$installer_pid"
[ -f "$(exec_active_dir)/abcd1234" ]
[ ! -f "$HOME/disrupted" ]
grep -q deferred "$base/installer-result"
echo 'ok task reservation and direct installer admission are atomic'
rm "$(exec_active_dir)/abcd1234"
cmd_fleet_tools install disruptive >/dev/null
[ "$(cat "$HOME/disrupted")" = 1 ]
echo 'ok the same installer runs after the task releases its reservation'
