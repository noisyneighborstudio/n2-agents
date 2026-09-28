#!/bin/sh
# Fleet flows through the packaged app's own CLI: enroll, sync, review and
# share, dispatch, fetch and revoke, against disposable peers. Every runtime
# file comes from the app bundle, not the checkout, so a file the build left
# out fails a flow. Test fixtures and helpers are linked from the checkout.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app=${1:-$repo/tray/build/N2 Agents.app}
resources=$app/Contents/Resources
[ -x "$resources/agents" ] || { echo "build first: N2_QA=1 N2_SIGN_IDENTITY=- zsh tray/build.sh" >&2; exit 2; }
root=$(mktemp -d "${TMPDIR:-/tmp}/n2-packaged-flows.XXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM
cp -R "$resources/." "$root/"
for dir in scripts tests shell tray docs loop; do ln -s "$repo/$dir" "$root/$dir"; done
echo "Packaged CLI: $resources/agents"
N2_FLEET_REQUIRE_LIVE_SSH=1 sh "$root/scripts/test-fleet.sh"
sh "$root/scripts/test-sync-review.sh"
echo "Packaged fleet flows passed"
