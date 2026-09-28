#!/bin/sh
# `agents update` against a disposable fake app and a local appcast: it installs
# the feed's newest build, quits only that app, and replaces nothing when the
# download is tampered with, is a different app, or is not newer.
set -u
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2update.XXXXXX")
trap 'kill "$runner" 2>/dev/null; rm -rf "$base"' EXIT HUP INT TERM
runner=
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { fail=1; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
grep -q '\.\./app-update\.py' "$repo/tray/build.sh" && ok "the app bundle ships app-update.py" ||
  bad "the app bundle ships app-update.py" "missing from tray/build.sh"

make_app() {  # <dir> <build> <bundle id> -> signed N2 Agents.app under <dir>
  a="$1/N2 Agents.app"
  mkdir -p "$a/Contents/MacOS" "$a/Contents/Resources"
  cp /bin/sleep "$a/Contents/MacOS/N2 Agents"
  for f in agents vendors.sh fleet.sh fleet-sync.sh fleet-exec.sh app-update.py; do cp "$repo/$f" "$a/Contents/Resources/"; done
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $3" -c "Add :CFBundleVersion string $2" \
    -c "Add :CFBundleShortVersionString string 9.0.$2" -c "Add :CFBundleExecutable string N2 Agents" \
    -c "Add :CFBundlePackageType string APPL" \
    -c "Add :N2AgentsStableFeedURL string file://$base/appcast.xml" "$a/Contents/Info.plist" >/dev/null
  codesign --force --deep --sign - "$a" 2>/dev/null
}
release() {  # <name> <build> <bundle id> [tamper] -> zip under $base/<name>.zip
  mkdir -p "$base/$1"
  make_app "$base/$1" "$2" "$3"
  [ -z "${4:-}" ] || printf 'tampered' >> "$base/$1/N2 Agents.app/Contents/Resources/vendors.sh"
  ( cd "$base/$1" && ditto -c -k --keepParent "N2 Agents.app" "$base/$1.zip" )
}
feed() {  # <zip> <build>
  printf '<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="file://%s" sparkle:version="%s" sparkle:shortVersionString="9.0.%s" length="%s" type="application/octet-stream"/></item></channel></rss>' \
    "$1" "$2" "$2" "$(wc -c < "$1" | tr -d ' ')" > "$base/appcast.xml"
}
installed="$base/installed/N2 Agents.app"
mkdir -p "$base/installed"
make_app "$base/installed" 1 dev.test.n2update
update() { HOME="$base/home" "$installed/Contents/Resources/agents" update --channel stable "$@" 2>&1; }
build() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed/Contents/Info.plist"; }
mkdir -p "$base/home"

release tampered 2 dev.test.n2update tamper; feed "$base/tampered.zip" 2
out=$(update); [ "$(build)" = 1 ] && case $out in *"not validly signed"*) ok "a tampered download is refused";; *) bad "tampered download" "$out";; esac ||
  bad "a tampered download replaced the app" "$out"
release other 2 dev.test.somethingelse; feed "$base/other.zip" 2
out=$(update); [ "$(build)" = 1 ] && case $out in *"different app"*) ok "a different app is refused";; *) bad "different app" "$out";; esac ||
  bad "a different app replaced this one" "$out"

release good 2 dev.test.n2update; feed "$base/good.zip" 2
case $(update --check) in *"Update available: 9.0.2"*) ok "--check reports the newer build";; *) bad "--check" "$(update --check)";; esac
[ "$(build)" = 1 ] && ok "--check installs nothing" || bad "--check installed"
"$installed/Contents/MacOS/N2 Agents" 600 & runner=$!
out=$(update)
if kill -0 "$runner" 2>/dev/null; then bad "the running app was not quit" "$out"; else ok "only the installed app's process was quit"; fi
[ "$(build)" = 2 ] && codesign --verify --deep --strict "$installed" 2>/dev/null &&
  ok "the feed's newest build is installed and verifies" || bad "install" "$out"
case $(update) in *"is up to date"*) ok "an installed newest build is up to date";; *) bad "up to date" "$(update)";; esac
[ -z "$(ls "$base/installed" | grep -v '^N2 Agents.app$')" ] && ok "no previous copy is left behind" ||
  bad "leftovers" "$(ls "$base/installed")"

[ "$fail" = 0 ] && echo "Update tests passed"
exit "$fail"
