#!/bin/sh
# The invite window shows exactly what the CLI minted: run the real CLI in a
# throwaway fleet and parse its output the way the app does.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/n2invite.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/home"
cli() { HOME="$work/home" N2_AGENTS_ROOT="$work/home/.n2-agents" N2_FLEET_HOSTNAME=n2-invite-test "$repo/agents" "$@"; }
cli fleet init --machine invite-test >/dev/null
cli fleet invite > "$work/minted" 2>&1
cli fleet id --host-key > "$work/hostkey" 2>/dev/null || : > "$work/hostkey"
swiftc -warnings-as-errors -parse-as-library "$repo/tray/FleetModel.swift" "$repo/tests/FleetInviteTests.swift" -o "$work/proof"
"$work/proof" "$work/minted" "$work/hostkey" "$work/home/.n2-agents/fleet/invites"
