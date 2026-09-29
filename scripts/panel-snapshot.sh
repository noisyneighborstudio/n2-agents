#!/bin/zsh
# Renders panel states over the fixture fleet in tests/PanelSnapshot.swift.
# Usage: scripts/panel-snapshot.sh <out-dir> <state>...   (state: fleet, profile/Default, slot/Default/codex, …)
# Each state is written as <out-dir>/<state>-light.png and -dark.png. With no
# state it only builds, which is how scripts/test.sh keeps it compiling.
set -euo pipefail
cd "${0:A:h}/.."
out=${1:?usage: panel-snapshot.sh <out-dir> <state>...}; shift
mkdir -p "$out"
work=$(mktemp -d "${TMPDIR:-/tmp}/n2snapshot.XXXXXX")
trap 'rm -rf "$work"' EXIT
# The app delegate (main.swift below its shared types, FleetControl.swift) is
# the live app; the views and model compile without it.
awk '/^final class AppDelegate/ {exit} {print}' tray/main.swift > "$work/MainTypes.swift"
swiftc -parse-as-library -o "$work/panel-snapshot" "$work/MainTypes.swift" \
  ${(f)"$(ls tray/*.swift | grep -v -e '/main.swift$' -e '/FleetControl.swift$')"} tests/PanelSnapshot.swift
# LabMark reads logos from the executable's resource directory.
cp -R tray/logos "$work/logos"
for state in "$@"; do
  for look in light dark; do
    "$work/panel-snapshot" "$state" "$look" "$out/${state//\//-}-$look.png"
  done
done
