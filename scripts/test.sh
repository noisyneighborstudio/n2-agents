#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

test_root="$PWD/.test-tmp"
rm -rf "$test_root"
mkdir -p "$test_root/tmp" "$test_root/cache/clang" "$test_root/cache/swift"
trap 'rm -rf "$test_root"' EXIT
export TMPDIR="$test_root/tmp"
export CLANG_MODULE_CACHE_PATH="$test_root/cache/clang"
export SWIFT_MODULECACHE_PATH="$test_root/cache/swift"

# Fake vendor CLIs. Each echoes the config-dir env var it was handed, which is
# exactly what the pinning tests need to assert — and it keeps the whole suite
# from touching a real login.
fake_bin="$test_root/fake-bin"
mkdir -p "$fake_bin"
for v in claude codex grok gemini cursor-agent opencode; do
  cat > "$fake_bin/$v" <<'FAKE'
#!/bin/sh
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-} CODEX_HOME=${CODEX_HOME:-} GROK_HOME=${GROK_HOME:-} CURSOR_CONFIG_DIR=${CURSOR_CONFIG_DIR:-} XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-}"
FAKE
  chmod +x "$fake_bin/$v"
done
# The keychain is the real user's even under a fake HOME: a stand-in
# `security` that finds nothing keeps tests off real logins (and the network).
printf '#!/bin/sh\nexit 44\n' > "$fake_bin/security"
chmod +x "$fake_bin/security"
fake_path="$fake_bin:/usr/bin:/bin"

# --- syntax ----------------------------------------------------------------
sh -n agents vendors.sh shell/agent-as
zsh -n install.sh uninstall.sh make-claude-profile.sh repatch-claude-profiles.sh tray/build.sh \
  scripts/release-build.sh scripts/make-appcast.sh scripts/release-prepare.sh \
  scripts/publish-appcast.sh shell/agents.zsh
bash -n shell/agents.bash
command -v fish >/dev/null && fish -n shell/agents.fish
swiftc -typecheck tray/main.swift tray/UpdateChannel.swift tray/Vendors.swift tray/ProfileColor.swift \
  tray/PanelModel.swift tray/PanelView.swift tray/ProfileSetup.swift tray/GlassWindow.swift tray/ShellPath.swift
swiftc -typecheck tray/icon-badge/main.swift tray/ProfileColor.swift
swiftc -typecheck scripts/make-icon.swift
swiftc -typecheck scripts/verify-signature.swift
channel_test=$(mktemp -d "$TMPDIR/channel.XXXXXX")/update-channel-tests
swiftc tray/UpdateChannel.swift tests/UpdateChannelTests.swift -o "$channel_test"
"$channel_test"
path_test=$(mktemp -d "$TMPDIR/shellpath.XXXXXX")/shell-path-tests
swiftc tray/ShellPath.swift tests/ShellPathTests.swift -o "$path_test"
"$path_test"

# --- vendor adapter table --------------------------------------------------
# The isolation tier is the single most load-bearing fact in the app: an `env`
# vendor can be pinned per process, a `swap` vendor can only be switched
# globally. Assert the tier for each lab so a bad edit to vendors.sh is caught
# here rather than by silently running an agent as the wrong account.
adapter=$(sh -c '. ./vendors.sh; for v in $N2_VENDORS; do echo "$v $(vendor_isolation "$v") $(vendor_env "$v")"; done')
print -r -- "$adapter" | grep -qx 'claude env CLAUDE_CONFIG_DIR'
print -r -- "$adapter" | grep -qx 'codex env CODEX_HOME'
print -r -- "$adapter" | grep -qx 'grok env GROK_HOME'
print -r -- "$adapter" | grep -qx 'cursor env CURSOR_CONFIG_DIR'
print -r -- "$adapter" | grep -qx 'opencode env XDG_CONFIG_HOME'
# Gemini reads GEMINI_DIR as a source constant (".gemini"), never from the
# environment — so it must stay swap-only until that changes upstream.
print -r -- "$adapter" | grep -qx 'gemini swap '

# opencode is the one vendor whose env var names the PARENT of its config dir.
slot=$(sh -c '. ./vendors.sh; vendor_slot_name opencode')
test "$slot" = "opencode/opencode"
test "$(sh -c '. ./vendors.sh; vendor_env_value opencode /root/P/opencode/opencode')" = "/root/P/opencode"
test "$(sh -c '. ./vendors.sh; vendor_env_value claude /root/P/claude')" = "/root/P/claude"

# --- profile lifecycle, multi-vendor ---------------------------------------
home="$test_root/home"
mkdir -p "$home"
run_agents() { HOME="$home" PATH="$fake_path" ./agents "$@" }

run_agents new Work --vendors claude,codex,grok,gemini --cli-only >/dev/null
for v in claude codex grok gemini; do test -d "$home/.n2-agents/Work/$v"; done
# The last entry of a comma list must survive the parse — `read` drops a final
# line with no trailing newline, which silently lost one vendor once.
test -d "$home/.n2-agents/Work/gemini"

run_agents profiles | grep -qx Work

# Each vendor is pinned through its OWN env var, and only its own.
out=$(run_agents run Work --vendor claude)
[[ $out == *"CLAUDE_CONFIG_DIR=$home/.n2-agents/Work/claude"* ]]
[[ $out == *"CODEX_HOME= "* ]]
out=$(run_agents run Work --vendor codex)
[[ $out == *"CODEX_HOME=$home/.n2-agents/Work/codex"* ]]
out=$(run_agents run Work --vendor grok)
[[ $out == *"GROK_HOME=$home/.n2-agents/Work/grok"* ]]

# A swap-only vendor must refuse to run as a non-active profile without
# --switch, because there is no way to pin it per process. The slot exists, so
# this can only be the isolation guard talking.
if run_agents run Work --vendor gemini >/dev/null 2>&1; then
  echo "swap-only vendor ran without --switch" >&2
  exit 1
fi
run_agents run Work --vendor gemini --switch >/dev/null
test "$(run_agents active --vendor gemini)" = Work

# `use` moves every installed vendor at once.
run_agents use Work >/dev/null
test "$(run_agents active)" = Work
for v in claude codex grok gemini; do
  test "$(readlink "$home/.$v")" = "$home/.n2-agents/Work/$v"
done

# …and back again, without losing the migrated Default.
run_agents use Default >/dev/null
test "$(run_agents active)" = Default
test -d "$home/.n2-agents/Default/claude"
# A dot dir must never point at itself: switching to Default for a vendor that
# had no config dir once produced ~/.claude -> ~/.claude.
for v in claude codex grok gemini; do
  test "$(readlink "$home/.$v")" != "$home/.$v"
  test -d "$home/.$v"
done

# Mixed state is reported as such rather than silently picking one.
run_agents use Work --vendor codex >/dev/null
test "$(run_agents active)" = mixed

# --- porcelain contract (the tray parses this) -----------------------------
porcelain=$(run_agents porcelain)
print -r -- "$porcelain" | grep -q '^V	claude	1	env	clone	oauth	Claude Code	projects	CC	Claude Desktop	com.anthropic.claudefordesktop$'
print -r -- "$porcelain" | grep -q '^P	Work	'
print -r -- "$porcelain" | grep -q '^A	'
# One S row per slot: its directory (the tray watches it during a sign-in)
# and the account read from the vendor's own files.
print -r -- "$porcelain" | grep -qx "S	Work	codex	$home/.n2-agents/Work/codex		no"
# Every P row lists its vendors as comma-separated <vendor>:<state> pairs.
print -r -- "$porcelain" | awk -F'\t' '$1=="P" && $4!="-" {print $4}' \
  | grep -qE '^[a-z]+:(active|ok)(,[a-z]+:(active|ok))*$'

# The quota meters parse `best --porcelain`: five tab-separated fields, and a
# vendor with no usage API says so per row instead of printing an empty table.
printf '{"oauthAccount": {"emailAddress": "work@example.com"}}' > "$home/.n2-agents/Work/claude/.claude.json"
porcelain=$(run_agents porcelain)
print -r -- "$porcelain" | grep -qx "S	Work	claude	$home/.n2-agents/Work/claude	work@example.com	no"
# Signed in = the slot holds the lab's own credential file (codex: auth.json);
# cursor keeps its login outside the slot, so it can only say unknown.
echo '{}' > "$home/.n2-agents/Work/codex/auth.json"
authed=$(run_agents authed Work)
print -r -- "$authed" | grep -qx 'codex	yes'
print -r -- "$authed" | grep -qx 'grok	no'
print -r -- "$authed" | grep -qx 'cursor	unknown'
rm "$home/.n2-agents/Work/codex/auth.json"
usage=$(run_agents best --porcelain --vendor codex)
print -r -- "$usage" | grep -qx 'Work	-	-	-	no-usage-api'

# Recent sessions span labs, newest first, and skip injected context to reach
# the first real prompt.
mkdir -p "$home/.n2-agents/Work/claude/projects/p" "$home/.n2-agents/Work/codex/sessions/2026/01/01"
cat > "$home/.n2-agents/Work/claude/projects/p/c1.jsonl" <<'JSONL'
{"type":"user","cwd":"/src/alpha","isMeta":true,"message":{"role":"user","content":"Caveat: injected"}}
{"type":"user","cwd":"/src/alpha","message":{"role":"user","content":[{"type":"text","text":"fix the parser"}]}}
JSONL
cat > "$home/.n2-agents/Work/codex/sessions/2026/01/01/rollout-2026-01-01T00-00-00-x1.jsonl" <<'JSONL'
{"type":"session_meta","payload":{"cwd":"/src/beta"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /src/beta"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ship the release"}]}}
JSONL
touch -t 202601010000 "$home/.n2-agents/Work/claude/projects/p/c1.jsonl"
recent=$(run_agents sessions --porcelain --limit 2)
test "$(print -r -- "$recent" | sed -n 1p | cut -f1-3,5,6)" = "Work	codex	x1	/src/beta	ship the release"
test "$(print -r -- "$recent" | sed -n 2p | cut -f1-3,5,6)" = "Work	claude	c1	/src/alpha	fix the parser"
test "$(run_agents sessions --porcelain Work --vendor claude | wc -l | tr -d ' ')" = 1

# login signs the pinned slot out and back in through the CLI's own commands.
out=$(run_agents login Work --vendor codex 2>&1)
# A fresh slot has nothing to sign out of: login, then status.
test "$(print -r -- "$out" | grep -c "CODEX_HOME=$home/.n2-agents/Work/codex")" = 2
# A signed-in one signs out first: logout, login, status — each pinned.
echo '{}' > "$home/.n2-agents/Work/codex/auth.json"
out=$(run_agents login Work --vendor codex 2>&1)
test "$(print -r -- "$out" | grep -c "CODEX_HOME=$home/.n2-agents/Work/codex")" = 3
rm "$home/.n2-agents/Work/codex/auth.json"
# A swap lab without its own logout clears the saved credentials instead — and
# like `run`, only once the profile is allowed to become the active one.
echo creds > "$home/.n2-agents/Work/gemini/oauth_creds.json"
if run_agents login Work --vendor gemini >/dev/null 2>&1; then
  echo "login switched a swap vendor without --switch" >&2
  exit 1
fi
test -f "$home/.n2-agents/Work/gemini/oauth_creds.json"
run_agents login Work --vendor gemini --switch >/dev/null 2>&1
test ! -e "$home/.n2-agents/Work/gemini/oauth_creds.json"

# --- next best: no lab is anyone's default -------------------------------
# Cursor and opencode keep their logins out of sight, so a slot of theirs can
# only be taken at its word; drop theirs so every slot here is checkable.
rm -rf "$home"/.n2-agents/{Default,Work}/{cursor,opencode}
# Nothing signed in: nothing to guess.
if run_agents run >/dev/null 2>&1; then echo "run picked a slot with nothing signed in" >&2; exit 1; fi
# Commands that act on one lab ask rather than defaulting to the first.
if run_agents login Work >/dev/null 2>&1; then echo "login guessed a lab" >&2; exit 1; fi
rm -f "$home/.n2-agents/.last-slot"
echo '{}' > "$home/.n2-agents/Work/codex/auth.json"
echo '{}' > "$home/.n2-agents/Work/grok/auth.json"
# The only signed-in slots are Work's Codex and Grok, so that's where it goes…
out=$(run_agents run 2>&1)
[[ $out == *"CODEX_HOME=$home/.n2-agents/Work/codex"* ]]
test "$(cat "$home/.n2-agents/.last-slot")" = "Work:codex"
# …then on round the rotation, skipping what isn't signed in…
out=$(run_agents run 2>&1)
[[ $out == *"GROK_HOME=$home/.n2-agents/Work/grok"* ]]
out=$(run_agents run 2>&1)
[[ $out == *"CODEX_HOME=$home/.n2-agents/Work/codex"* ]]
# …and a profile alone, or a lab alone, fills in the other half the same way.
out=$(run_agents run Work 2>&1)
[[ $out == *"GROK_HOME=$home/.n2-agents/Work/grok"* ]]
out=$(run_agents run --vendor codex 2>&1)
[[ $out == *"CODEX_HOME=$home/.n2-agents/Work/codex"* ]]
porcelain=$(run_agents porcelain)
print -r -- "$porcelain" | grep -qx "L	Work	codex"
rm "$home/.n2-agents/Work/codex/auth.json" "$home/.n2-agents/Work/grok/auth.json"

# --- adopt: shares claudes state, never copies it --------------------------
adopt_home="$test_root/adopt-home"
mkdir -p "$adopt_home/.claude-profiles/Default" "$adopt_home/.claude-profiles/ExpoIO"
echo token > "$adopt_home/.claude-profiles/ExpoIO/.credentials.json"
HOME="$adopt_home" PATH="$fake_path" ./agents adopt --yes >/dev/null 2>&1
# A symlink, so both apps read one login; a copy would force a re-login because
# Claude Code keys its keychain entry to the config dir path.
test -L "$adopt_home/.n2-agents/ExpoIO/claude"
test "$(readlink "$adopt_home/.n2-agents/ExpoIO/claude")" = "$adopt_home/.claude-profiles/ExpoIO"
test "$(cat "$adopt_home/.n2-agents/ExpoIO/claude/.credentials.json")" = token
# The legacy tree is untouched — `claudes` must keep working.
test -d "$adopt_home/.claude-profiles/ExpoIO"

# Adopted profiles resolve as active through the symlink indirection.
HOME="$adopt_home" PATH="$fake_path" ./agents use ExpoIO --vendor claude >/dev/null
test "$(HOME="$adopt_home" PATH="$fake_path" ./agents active --vendor claude)" = ExpoIO

# --- reserved and invalid names --------------------------------------------
for bad in As default; do
  if HOME="$test_root/names" PATH="$fake_path" ./agents new "$bad" --cli-only >/dev/null 2>&1; then
    echo "Reserved profile name '$bad' was accepted" >&2
    exit 1
  fi
done
if ./make-claude-profile.sh As >/dev/null 2>&1; then
  echo "Reserved profile name was accepted by make-claude-profile.sh" >&2
  exit 1
fi
# An unknown vendor must fail loudly instead of quietly creating nothing.
if HOME="$test_root/names" PATH="$fake_path" ./agents new Nope --vendors notalab --cli-only >/dev/null 2>&1; then
  echo "Unknown vendor was accepted" >&2
  exit 1
fi

# Claude Desktop missing: cloning fails loudly and points at --cli-only.
missing_app="$test_root/no-claude/Claude.app"
clone_error=$(N2_CLAUDE_APP="$missing_app" ./make-claude-profile.sh Work 2>&1 || true)
[[ $clone_error == *--cli-only* ]]

# --- PATH shims ------------------------------------------------------------
shim_home="$test_root/shim-home"
shim_bin="$shim_home/.local/bin"
foreign_bin="$test_root/foreign-bin"
mkdir -p "$shim_home/.n2-agents/Expo/claude" "$shim_home/.n2-agents/Expo/codex" \
  "$shim_bin" "$foreign_bin" "$test_root/foreign"
ln -s /usr/bin/false "$foreign_bin/claude-expo"
ln -s "$test_root/foreign/agent-as" "$shim_bin/claude-client"
ln -s "$PWD/agents" "$shim_bin/agents"

HOME="$shim_home" PATH="/usr/bin:/bin" sh -c '
  set -- help
  . "$0" >/dev/null
  test "$(bin_dir)" = "$HOME/.local/bin"
' "$PWD/agents"
test "$(cat "$shim_home/.n2-agents/.bin-dir")" = "$shim_bin"

HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" ./agents shims >/dev/null

# Shims exist per (vendor, profile) that actually has a slot…
for name in claude-as codex-as claude-expo codex-expo; do
  test "$(readlink "$shim_bin/$name")" = "$PWD/shell/agent-as"
done
# …and not for vendors the profile has no slot for.
test ! -e "$shim_bin/grok-expo"
# Foreign links are never clobbered.
test "$(readlink "$shim_bin/claude-client")" = "$test_root/foreign/agent-as"

# A shim left pointing into the pre-rename N2Agents.app is ours: re-pointed.
ln -sf "/Applications/N2Agents.app/Contents/Resources/agent-as" "$shim_bin/claude-expo"
HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" ./agents shims >/dev/null
test "$(readlink "$shim_bin/claude-expo")" = "$PWD/shell/agent-as"

# Concurrent syncs must not leave the lock behind.
HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" TMPDIR="$test_root/one" ./agents shims >/dev/null &
first=$!
HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" TMPDIR="$test_root/two" ./agents shims >/dev/null &
second=$!
wait $first
wait $second
test ! -e "$shim_home/.n2-agents/.shims.lock"

# A shim dispatches to the right vendor: the name carries both halves.
HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" "$shim_bin/codex-expo" \
  | grep -q "CODEX_HOME=$shim_home/.n2-agents/Expo/codex"

HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" ./agents shims --remove >/dev/null
test ! -e "$shim_bin/claude-expo"
test "$(readlink "$shim_bin/claude-client")" = "$test_root/foreign/agent-as"

# --- shell helpers load ----------------------------------------------------
HOME="$shim_home" PATH="/usr/bin:/bin" zsh -c 'source shell/agents.zsh; command -v agents >/dev/null'
HOME="$shim_home" PATH="/usr/bin:/bin" bash -c 'source shell/agents.bash; command -v agents >/dev/null'
if command -v fish >/dev/null; then
  HOME="$shim_home" PATH="/usr/bin:/bin" "$(command -v fish)" -c 'source shell/agents.fish; command -q agents'
fi

# --- release plumbing ------------------------------------------------------
# One appcast per channel, with the enclosure URL publish-appcast.sh builds
# from updates.env, and the version pair Sparkle orders by.
source ./updates.env
appcast_test=$(mktemp -d "$TMPDIR/appcast.XXXXXX")
signature=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==
for channel version in continuous 1.4.0-continuous.3 stable 1.4.0; do
  zip_name="N2Agents-$channel-$version.zip"
  printf artifact > "$appcast_test/$zip_name"
  url="https://github.com/$N2_UPDATES_REPO/releases/download/v$version/$zip_name"
  ./scripts/make-appcast.sh "$channel" "$version" 1001 "$url" \
    "$appcast_test/$zip_name" "$signature" "$appcast_test/$channel.xml"
  xml=$(<"$appcast_test/$channel.xml")
  [[ $xml == *"<sparkle:channel>$channel</sparkle:channel>"* ]]
  [[ $xml == *"<enclosure url=\"$url\" sparkle:version=\"1001\" sparkle:shortVersionString=\"$version\" length=\"8\""* ]]
  [[ $xml == *"sparkle:edSignature=\"$signature\""* ]]
  xmllint --noout "$appcast_test/$channel.xml"
done
if ./scripts/make-appcast.sh stable 1.0 1 https://example.invalid/N2Agents-continuous-1.4.0-continuous.3.zip \
  "$appcast_test/N2Agents-continuous-1.4.0-continuous.3.zip" "$signature" "$appcast_test/bad.xml" 2>/dev/null; then
  echo "Wrong-channel appcast was accepted" >&2
  exit 1
fi

# Update hosting has one source: updates.env. install.sh runs piped, so it
# carries a copy of the repo, which must match.
grep -Fqx "UPDATES_REPO=\"$N2_UPDATES_REPO\"" install.sh
grep -Fq 'source ../updates.env' tray/build.sh
grep -Fq 'source ./updates.env' scripts/publish-appcast.sh
# (`! grep` would never trip set -e, hence the explicit exits.)
grep -Fq 'FeedURL</key>' tray/Info.plist && { echo "feed URL hard-coded in Info.plist" >&2; exit 1 }
# No leftovers from the claudes fork in the release path.
grep -in claudes .github/workflows/release.yml .releaserc.json scripts/release-*.sh \
  scripts/publish-appcast.sh scripts/make-appcast.sh tray/build.sh docs/releases.md \
  && { echo "claudes-era names left in the release path" >&2; exit 1 }

grep -Fq 'branches: [main, stable]' .github/workflows/release.yml
grep -Fq 'refs/heads/main) channel=continuous' .github/workflows/release.yml
grep -Fq 'refs/heads/stable) channel=stable' .github/workflows/release.yml
grep -Fq 'N2_BUILD_NUMBER: ${{ github.run_number }}' .github/workflows/release.yml
grep -Fq 'npx semantic-release' .github/workflows/release.yml
grep -Fq '"branches": ["stable", { "name": "main", "prerelease": "continuous" }]' .releaserc.json
grep -Fq 'release-prepare.sh ${nextRelease.version}' .releaserc.json
grep -Fq 'publish-appcast.sh ${nextRelease.version} ${nextRelease.gitTag}' .releaserc.json
grep -Fq 'cp N2Agents.zip "N2Agents-${channel}-${version}.zip"' scripts/release-prepare.sh
grep -Fq '@executable_path/../Frameworks' Package.swift
grep -Fq 'push --quiet "$remote" HEAD:appcasts' scripts/publish-appcast.sh
grep -Fq 'allowedChannels' tray/main.swift
grep -Fq 'UpdateChannel.preferenceKey' tray/main.swift

# The tray must not re-implement profile discovery: it parses the CLI instead.
grep -Fq 'Snapshot.parse' tray/main.swift
grep -Fq 'runCLI(["porcelain"])' tray/main.swift

# Every bundled script runs with the login shell's PATH: under launchd's four
# directories the CLI finds no lab installed and the panel comes back empty.
[ "$(grep -c 'task.environment = Self.scriptEnvironment' tray/main.swift)" = "$(grep -c 'task.arguments = \[\(cliPath\|scriptsDir\)' tray/main.swift)" ]

# The window server shades the window's alpha: the glass sits in a rounded
# clip, or its rectangular backing layer casts a square shadow.
grep -Fq 'clip.layer?.masksToBounds = true' tray/GlassWindow.swift
grep -Fq 'hasShadow = true' tray/GlassWindow.swift

echo "All tests passed"
