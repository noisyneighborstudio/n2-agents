#!/bin/sh
# Focused fault injection at the transport boundary. This is not live SSH proof.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2delivery.XXXXXX")
trap 'rm -rf "$base"' EXIT
. "$repo/fleet-exec.sh"
fleet_root=$base/fleet
fleet_meta() { cat "$1/$2" 2>/dev/null; }
fleet_meta_set() { mkdir -p "$1"; printf '%s\n' "$3" > "$1/$2"; }
fleet_now() { date +%s; }
fleet_event() { :; }
fleet_header() { awk -F= -v k="$2" '$1==k {print $2}' "$1"; }
exec_fanout() { printf '%s\n' "$1" >> "$base/notices"; }
exec_notify() { :; }
exec_bundle_build() { printf 'synthetic request'; }
exec_plan() { printf 'first\tfast\tcursor\t1\tnone\nsecond\tslow\tcursor\t2\tnone\n' > "$1/plan"; }
fleet_call() {
  if [ "$2" = task-status ]; then printf 'state=completed\nrc=0\n'; return 0; fi
  printf '%s\n' "$1" >> "$base/deliveries"
  id=$(sed -n 's/^task=//p' "$3")
  # The caller must be durable before the receiver can execute anything.
  [ "$(exec_meta "$id" peer)" = first ] || exit 91
  case $scenario in
    lost) printf '%s\n' "$id" > "$base/accepted"; return 1 ;;
    malformed) printf 'unexpected reply\n' ;;
    early) exec_set_state "$id" completed; printf 'accepted %s\n' "$id" ;;
    normal) printf 'accepted %s\n' "$id" ;;
  esac
}
for scenario in lost malformed early normal; do
  : > "$base/deliveries"
  out=$(exec_dispatch 'task' '' '' '' '' '' label '')
  id=$(printf '%s\n' "$out" | cut -f1)
  [ "$(cat "$base/deliveries")" = first ]
  [ "$(exec_meta "$id" peer)" = first ]
  case $scenario in
    lost|malformed)
      [ "$(exec_meta "$id" state)" = unreachable ]
      exec_reconcile "$id" > /dev/null
      [ "$(exec_meta "$id" state)" = completed ]
      [ "$(cat "$base/deliveries")" = first ] ;;
    early) [ "$(exec_meta "$id" state)" = completed ] ;;
    normal) [ "$(exec_meta "$id" state)" = dispatched ] ;;
  esac
  printf 'ok %s: one destination, durable state, correct reconciliation\n' "$scenario"
done
