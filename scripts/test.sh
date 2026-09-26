#!/bin/zsh
set -euo pipefail
TRAPZERR() { print -u2 -- "Test command failed at ${funcfiletrace[1]}"; }
cd "${0:A:h}/.."

test_root="$PWD/.test-tmp"
rm -rf "$test_root"
mkdir -p "$test_root/tmp" "$test_root/cache/clang" "$test_root/cache/swift"
trap 'rm -rf "$test_root"' EXIT
export TMPDIR="$test_root/tmp"
export N2_CODEX_USAGE_URL="file://$test_root/codex-usage.json"
export CLANG_MODULE_CACHE_PATH="$test_root/cache/clang"
export SWIFT_MODULECACHE_PATH="$test_root/cache/swift"
# Provider-path assertions describe the disposable fixture, independent of
# whichever account/home the host coding agent inherited.
unset CODEX_HOME CLAUDE_CONFIG_DIR GROK_HOME CURSOR_CONFIG_DIR XDG_CONFIG_HOME TBH_CREDENTIAL_BACKEND
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_SECURESTORAGE_CONFIG_DIR


# Fake vendor CLIs. Each echoes the config-dir env var it was handed, which is
# exactly what the pinning tests need to assert — and it keeps the whole suite
# from touching a real login.
fake_bin="$test_root/fake-bin"
mkdir -p "$fake_bin"
for v in claude codex grok cursor-agent opencode muse; do
  cat > "$fake_bin/$v" <<'FAKE'
#!/bin/sh
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-} CODEX_HOME=${CODEX_HOME:-} GROK_HOME=${GROK_HOME:-} CURSOR_CONFIG_DIR=${CURSOR_CONFIG_DIR:-} XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-} TBH_CREDENTIAL_BACKEND=${TBH_CREDENTIAL_BACKEND:-}"
FAKE
  chmod +x "$fake_bin/$v"
done
# Grok's usage comes from `grok agent stdio` (ACP). The fake answers the two
# calls, with billing read from the GROK_HOME it was pinned to.
cat > "$fake_bin/grok" <<'FAKE'
#!/bin/sh
if [ "${1:-} ${2:-}" = "agent stdio" ]; then
  while IFS= read -r line; do
    case $line in
      *'"id": 1'*) echo 'notice: MCP env would print here' ;
                   echo '{"jsonrpc": "2.0", "id": 1, "result": {}}' ;;
      *'"_x.ai/billing"'*) printf '{"jsonrpc": "2.0", "id": 2, "result": %s}\n' "$(cat "$GROK_HOME/billing.json")" ;;
    esac
  done
  exit 0
fi
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-} CODEX_HOME=${CODEX_HOME:-} GROK_HOME=${GROK_HOME:-} CURSOR_CONFIG_DIR=${CURSOR_CONFIG_DIR:-} XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-} TBH_CREDENTIAL_BACKEND=${TBH_CREDENTIAL_BACKEND:-}"
FAKE
# The keychain is the real user's even under a fake HOME: a stand-in
# `security` that finds nothing keeps tests off real logins (and the network).
cat > "$fake_bin/security" <<'FAKE'
#!/bin/sh
case "$*" in *cursor-access-token*) [ -n "${FAKE_CURSOR_TOKEN:-}" ] && { echo "$FAKE_CURSOR_TOKEN"; exit 0; } ;; esac
exit 44
FAKE
chmod +x "$fake_bin/security"
fake_path="$fake_bin:/usr/bin:/bin"

# --- syntax ----------------------------------------------------------------
sh -n agents vendors.sh fleet.sh fleet-sync.sh fleet-exec.sh scripts/test-fleet-spike.sh scripts/test-exec.sh scripts/test-native-ui.sh shell/agent-as
zsh -n install.sh uninstall.sh tray/build.sh \
  scripts/release-build.sh scripts/make-appcast.sh scripts/release-prepare.sh \
  scripts/publish-appcast.sh shell/agents.zsh
bash -n shell/agents.bash
command -v fish >/dev/null && fish -n shell/agents.fish
swiftc -typecheck tray/main.swift tray/UpdateChannel.swift tray/Vendors.swift tray/ProfileColor.swift tray/StatusIcon.swift tray/QuotaToast.swift tray/Ink.swift tray/LabMark.swift \
  tray/PanelModel.swift tray/UsageDetailsView.swift tray/PanelView.swift tray/SettingsWindowView.swift tray/FleetSyncSettings.swift tray/FleetSettingsLoader.swift tray/ProfileSetup.swift tray/GlassWindow.swift tray/ShellPath.swift tray/Hotkey.swift tray/FleetModel.swift tray/FleetView.swift tray/FleetControl.swift
sh scripts/test-panel-usage.sh
swiftc -typecheck scripts/make-icon.swift
swiftc -typecheck scripts/verify-signature.swift
channel_test=$(mktemp -d "$TMPDIR/channel.XXXXXX")/update-channel-tests
swiftc tray/UpdateChannel.swift tests/UpdateChannelTests.swift -o "$channel_test"
"$channel_test"
path_test=$(mktemp -d "$TMPDIR/shellpath.XXXXXX")/shell-path-tests
swiftc tray/ShellPath.swift tests/ShellPathTests.swift -o "$path_test"
"$path_test"
fleet_settings_test=$(mktemp -d "$TMPDIR/fleetsettings.XXXXXX")/fleet-settings-loader-tests
swiftc tray/FleetSettingsLoader.swift tray/ShellPath.swift tests/FleetSettingsLoaderTests.swift -o "$fleet_settings_test"
"$fleet_settings_test"
icon_test=$(mktemp -d "$TMPDIR/statusicon.XXXXXX")/status-icon-tests
swiftc tray/StatusIcon.swift tests/StatusIconTests.swift -o "$icon_test"
"$icon_test"

# --- vendor adapter table --------------------------------------------------
# The config-dir env var is the single most load-bearing fact in the app: it
# is how a process gets pinned to a profile. Assert it for each lab so a bad
# edit to vendors.sh is caught here rather than by silently running an agent as
# the wrong account — and so no lab lacks one.
adapter=$(sh -c '. ./vendors.sh; for v in $N2_VENDORS; do echo "$v $(vendor_env "$v")"; done')
test "$adapter" = "claude CLAUDE_CONFIG_DIR
codex CODEX_HOME
grok GROK_HOME
cursor CURSOR_CONFIG_DIR
opencode XDG_CONFIG_HOME
muse XDG_CONFIG_HOME"

# opencode and muse are the vendors whose env var names the PARENT of their config dir.
slot=$(sh -c '. ./vendors.sh; vendor_slot_name opencode')
test "$slot" = "opencode/opencode"
test "$(sh -c '. ./vendors.sh; vendor_env_value opencode /root/P/opencode/opencode')" = "/root/P/opencode"
test "$(sh -c '. ./vendors.sh; vendor_slot_name muse')" = "muse/muse"
test "$(sh -c '. ./vendors.sh; vendor_env_value muse /root/P/muse/muse')" = "/root/P/muse"
test "$(sh -c '. ./vendors.sh; vendor_env_value claude /root/P/claude')" = "/root/P/claude"

# --- profile lifecycle, multi-vendor ---------------------------------------
home="$test_root/home"
mkdir -p "$home"
run_agents() { HOME="$home" PATH="$fake_path" ./agents "$@" }

run_agents new Work --vendors claude,codex,grok,muse >/dev/null
for v in claude codex grok; do test -d "$home/.n2-agents/Work/$v"; done
# The last entry of a comma list must survive the parse — `read` drops a final
# line with no trailing newline, which silently lost one vendor once.
test -d "$home/.n2-agents/Work/muse/muse"

run_agents profiles | grep -qx Work

# Each vendor is pinned through its OWN env var, and only its own.
out=$(run_agents run Work --vendor claude)
[[ $out == *"CLAUDE_CONFIG_DIR=$home/.n2-agents/Work/claude"* ]]
[[ $out == *"CODEX_HOME= "* ]]
out=$(run_agents run Work --vendor codex)
[[ $out == *"CODEX_HOME=$home/.n2-agents/Work/codex"* ]]
out=$(run_agents run Work --vendor grok)
[[ $out == *"GROK_HOME=$home/.n2-agents/Work/grok"* ]]

# A sign-in names the profile and slot it writes to before the vendor's own
# prompt appears; ordinary runs stay quiet.
err=$(run_agents run Work --vendor codex login 2>&1 >/dev/null)
[[ $err == *"login for profile 'Work' (CODEX_HOME=$home/.n2-agents/Work/codex)"* ]]
err=$(run_agents run Work --vendor codex exec hi 2>&1 >/dev/null)
[[ -z $err ]]

# `use` moves every installed vendor at once.
run_agents use Work >/dev/null
test "$(run_agents active)" = Work
for v in claude codex grok; do
  test "$(readlink "$home/.$v")" = "$home/.n2-agents/Work/$v"
done

# …and back again, without losing the migrated Default.
run_agents use Default >/dev/null
test "$(run_agents active)" = Default
test -d "$home/.n2-agents/Default/claude"
# A dot dir must never point at itself: switching to Default for a vendor that
# had no config dir once produced ~/.claude -> ~/.claude.
for v in claude codex grok; do
  test "$(readlink "$home/.$v")" != "$home/.$v"
  test -d "$home/.$v"
done

# Mixed state is reported as such rather than silently picking one.
run_agents use Work --vendor codex >/dev/null
test "$(run_agents active)" = mixed

# --- porcelain contract (the tray parses this) -----------------------------
porcelain=$(run_agents porcelain)
print -r -- "$porcelain" | grep -q '^V	claude	1	instance	oauth	Claude Code	projects	CC	Claude Desktop	com.anthropic.claudefordesktop	7d$'
print -r -- "$porcelain" | grep -q '^V	codex	1	instance	oauth	Codex	sessions	CX	Codex	com.openai.codex	7d$'
# Cursor's long window is its monthly billing cycle.
print -r -- "$porcelain" | grep -q '^V	cursor	.*	mo$'
print -r -- "$porcelain" | grep -q '^P	Work	'
print -r -- "$porcelain" | grep -q '^A	'
# One S row per slot: its directory (the tray watches it during a sign-in),
# the account read from the vendor's own files, and its desktop app's data.
print -r -- "$porcelain" | grep -qx "S	Work	codex	$home/.n2-agents/Work/codex		no	$home/Library/Application Support/Codex-Work"
print -r -- "$porcelain" | grep -qx "S	Work	grok	$home/.n2-agents/Work/grok		no	"
# Every P row lists its vendors as comma-separated <vendor>:<state> pairs.
print -r -- "$porcelain" | awk -F'\t' '$1=="P" && $4!="-" {print $4}' \
  | grep -qE '^[a-z]+:(active|ok)(,[a-z]+:(active|ok))*$'

# The quota meters parse `best --porcelain`: five tab-separated fields, and a
# vendor with no usage API says so per row instead of printing an empty table.
printf '{"oauthAccount": {"emailAddress": "work@example.com"}}' > "$home/.n2-agents/Work/claude/.claude.json"
porcelain=$(run_agents porcelain)
print -r -- "$porcelain" | grep -qx "S	Work	claude	$home/.n2-agents/Work/claude	work@example.com	no	$home/Library/Application Support/Claude-Work"
# Signed in = the slot holds the lab's own credential file (codex: auth.json);
# cursor keeps its login outside the slot, so it can only say unknown.
echo '{}' > "$home/.n2-agents/Work/codex/auth.json"
authed=$(run_agents authed Work)
print -r -- "$authed" | grep -qx 'codex	yes'
print -r -- "$authed" | grep -qx 'grok	no'
print -r -- "$authed" | grep -qx 'cursor	unknown'
rm "$home/.n2-agents/Work/codex/auth.json"
usage=$(run_agents best --porcelain --vendor opencode)
print -r -- "$usage" | grep -qx 'Work	-	-	-	no-usage-api'
# Codex reports quota too. Signed out says so; signed in, each window lands in
# the column for its length (a weekly-only plan has no 5h figure), and a
# reached limit reads as full whatever the percentage.
usage=$(run_agents best --porcelain --vendor codex)
print -r -- "$usage" | grep -qx 'Work	-	-	-	no-token'
codex_usage() {  # used%, limit reached
  printf '{"rate_limit": {"limit_reached": %s, "primary_window": {"used_percent": %s, "limit_window_seconds": 604800, "reset_at": 1790411072}, "secondary_window": null}}' \
    "$2" "$1" > "$test_root/codex-usage.json"
}
export N2_CODEX_USAGE_URL="file://$test_root/codex-usage.json"
codex_auth='{"tokens": {"access_token": "t", "account_id": "a"}}'
echo "$codex_auth" > "$home/.n2-agents/Work/codex/auth.json"
codex_usage 44 false
usage=$(run_agents best --porcelain --vendor codex)
print -r -- "$usage" | grep -qx 'Work	-	44	-	ok	2026-09-26T08:24'
codex_usage 80 true
usage=$(run_agents best --porcelain --vendor codex)
print -r -- "$usage" | grep -qx 'Work	-	80	-	restricted	2026-09-26T08:24'
rm "$home/.n2-agents/Work/codex/auth.json"
# Grok has one weekly credit pool: its percent fills the 7d column, reset at
# the period's end in UTC. Signed in = an auth.x.ai entry in auth.json.
usage=$(run_agents best --porcelain --vendor grok)
print -r -- "$usage" | grep -qx 'Work	-	-	-	no-token'
grok_usage() {  # used%
  printf '{"config": {"creditUsagePercent": %s, "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-09-22T09:51:31.674043+00:00", "end": "2026-09-29T09:51:31.674043+00:00"}}}' \
    "$1" > "$home/.n2-agents/Work/grok/billing.json"
}
grok_auth='{"https://auth.x.ai::u1": {"key": "t", "email": "work@example.com"}}'
echo "$grok_auth" > "$home/.n2-agents/Work/grok/auth.json"
grok_usage 12.5
usage=$(run_agents best --porcelain --vendor grok)
print -r -- "$usage" | grep -qx 'Work	-	12.5	-	ok	2026-09-29T09:51'
rm "$home/.n2-agents/Work/grok/auth.json" "$home/.n2-agents/Work/grok/billing.json"
# Muse keeps one keychain login whatever XDG_CONFIG_HOME says, so a profile's
# runs pin the file backend and its login lands in the slot. Default keeps the
# keychain: it's the one a plain `muse` finds.
muse_slot="$home/.n2-agents/Work/muse/muse"
mkdir -p "$muse_slot"
out=$(run_agents run Work --vendor muse)
[[ $out == *"XDG_CONFIG_HOME=$home/.n2-agents/Work/muse TBH_CREDENTIAL_BACKEND=file"* ]]
test -z "$(sh -c '. ./vendors.sh; vendor_env_extra muse Default')"
# An auth.json that points at the keychain is Default's login, not the profile's.
echo '{"providers": {"meta": {"storage": "keychain"}}}' > "$muse_slot/auth.json"
run_agents authed Work | grep -qx 'muse	no'
usage=$(run_agents best --porcelain --vendor muse)
print -r -- "$usage" | grep -qx 'Work	-	-	-	no-token'
# Signed in, both windows come back: `window` is the 5-hour one.
echo '{"providers": {"meta": {"storage": "file", "access_token": "dca:t"}}}' > "$muse_slot/auth.json"
run_agents authed Work | grep -qx 'muse	yes'
printf '{"is_subs_active": true, "subs_usage": {"window": {"used_percent": 7, "window_duration_mins": 300, "resets_at": 1790411072}, "weekly": {"used_percent": 30, "resets_at": 1790911072}}}' \
  > "$test_root/muse-usage.json"
export N2_MUSE_USAGE_URL="file://$test_root/muse-usage.json"
usage=$(run_agents best --porcelain --vendor muse)
print -r -- "$usage" | grep -qx 'Work	7	30	2026-09-26T08:24	ok	2026-10-02T03:17'
rm -r "$home/.n2-agents/Work/muse"
# Cursor keeps one keychain login for the machine: Default reads it, in the
# long-window column (a monthly cycle), and other slots say they share it.
usage=$(run_agents best --porcelain --vendor cursor)
print -r -- "$usage" | grep -qx 'Default	-	-	-	no-token'
print -r -- "$usage" | grep -qx 'Work	-	-	-	shared-login'
cursor_usage() {  # used%
  printf '{"billingCycleEnd": "1792641563000", "planUsage": {"totalPercentUsed": %s}}' "$1" > "$test_root/cursor-usage.json"
}
export N2_CURSOR_USAGE_URL="file://$test_root/cursor-usage.json"
cursor_usage 0.4
usage=$(FAKE_CURSOR_TOKEN=t run_agents best --porcelain --vendor cursor)
print -r -- "$usage" | grep -qx 'Default	-	0.4	-	ok	2026-10-22T03:59'
# A slot on the shared login has Default's room: rotation reaches Work too…
out=$(FAKE_CURSOR_TOKEN=t run_agents run --vendor cursor 2>&1; FAKE_CURSOR_TOKEN=t run_agents run --vendor cursor 2>&1)
[[ $out == *"CURSOR_CONFIG_DIR=$home/.n2-agents/Work/cursor"* ]]
# …and at the limit, neither runs.
cursor_usage 99
if FAKE_CURSOR_TOKEN=t run_agents run --vendor cursor >/dev/null 2>&1; then
  echo "rotation ran a Cursor slot on a maxed shared login" >&2
  exit 1
fi

# Recent sessions span labs, newest first, and skip injected context to reach
# the first real prompt. Each carries its branch and the lab's name for it:
# Claude's latest ai-title, overruled by a /rename; Codex's thread index.
mkdir -p "$home/.n2-agents/Work/claude/projects/p" "$home/.n2-agents/Work/codex/sessions/2026/01/01"
cat > "$home/.n2-agents/Work/claude/projects/p/c1.jsonl" <<'JSONL'
{"type":"ai-title","aiTitle":"Parser work"}
{"type":"user","cwd":"/src/alpha","isMeta":true,"message":{"role":"user","content":"Caveat: injected"}}
{"type":"user","cwd":"/src/alpha","gitBranch":"main","entrypoint":"cli","message":{"role":"user","content":[{"type":"text","text":"fix the parser"}]}}
{"type":"ai-title","aiTitle":"Fix the \"parser\""}
{"type":"user","cwd":"/src/alpha","gitBranch":"seth/parser","entrypoint":"cli","message":{"role":"user","content":"more"}}
JSONL
cat > "$home/.n2-agents/Work/codex/sessions/2026/01/01/rollout-2026-01-01T00-00-00-x1.jsonl" <<'JSONL'
{"type":"session_meta","payload":{"cwd":"/src/beta","source":"cli","git":{"commit_hash":"abc","branch":"release"}}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /src/beta"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ship the release"}]}}
JSONL
print -r -- '{"id":"x1","thread_name":"Ship it","updated_at":"2026-01-01T00:00:00Z"}' \
  > "$home/.n2-agents/Work/codex/session_index.jsonl"
# Background transcripts leave files too — Codex's helpers (the tool-call
# reviewer) and `codex exec`, Claude's subagents and `claude -p` — and each
# is newer than the real ones here: none shows, and none uses up the limit.
cat > "$home/.n2-agents/Work/codex/sessions/2026/01/01/rollout-2026-01-01T00-00-01-g1.jsonl" <<'JSONL'
{"type":"session_meta","payload":{"cwd":"/src/beta","source":{"subagent":{"other":"guardian"}}}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"The following is the Codex agent history"}]}}
JSONL
print -r -- '{"type":"session_meta","payload":{"cwd":"/src/beta","source":"exec"}}' \
  > "$home/.n2-agents/Work/codex/sessions/2026/01/01/rollout-2026-01-01T00-00-02-e1.jsonl"
print -r -- '{"type":"user","cwd":"/tmp/t","entrypoint":"sdk-cli","message":{"role":"user","content":"Generate a title"}}' \
  > "$home/.n2-agents/Work/claude/projects/p/p1.jsonl"
mkdir -p "$home/.n2-agents/Work/claude/projects/p/c1/subagents"
print -r -- '{"type":"user","cwd":"/src/alpha","isSidechain":true,"entrypoint":"cli","message":{"role":"user","content":"research"}}' \
  > "$home/.n2-agents/Work/claude/projects/p/c1/subagents/agent-a1.jsonl"
touch -t 202601010000 "$home/.n2-agents/Work/claude/projects/p/c1.jsonl"
touch -t 202601010100 "$home/.n2-agents/Work/codex/sessions/2026/01/01/rollout-2026-01-01T00-00-00-x1.jsonl"
for f in codex/sessions/2026/01/01/rollout-2026-01-01T00-00-01-g1.jsonl codex/sessions/2026/01/01/rollout-2026-01-01T00-00-02-e1.jsonl \
         claude/projects/p/p1.jsonl claude/projects/p/c1/subagents/agent-a1.jsonl; do
  touch -t 202601020000 "$home/.n2-agents/Work/$f"
done
recent=$(run_agents sessions --porcelain --limit 2)
test "$(print -r -- "$recent" | sed -n 1p | cut -f1-3,5-)" = "Work	codex	x1	/src/beta	ship the release	release	Ship it"
test "$(print -r -- "$recent" | sed -n 2p | cut -f1-3,5-)" = 'Work	claude	c1	/src/alpha	fix the parser	seth/parser	Fix the "parser"'
test "$(run_agents sessions --porcelain Work --vendor claude | wc -l | tr -d ' ')" = 1
# A second listing reads the cache, and a transcript that changed is read again.
test "$(run_agents sessions --porcelain --limit 2)" = "$recent"
print -r -- '{"type":"custom-title","customTitle":"Renamed"}' >> "$home/.n2-agents/Work/claude/projects/p/c1.jsonl"
touch -t 202601010000 "$home/.n2-agents/Work/claude/projects/p/c1.jsonl"
touch -t 202601010001 "$home/.n2-agents/Work/claude/projects/p/c1.jsonl"
test "$(run_agents sessions --porcelain Work --vendor claude | cut -f8)" = "Renamed"

# login signs the pinned slot out and back in through the CLI's own commands.
out=$(run_agents login Work --vendor codex 2>&1)
# A fresh slot has nothing to sign out of: login, then status.
test "$(print -r -- "$out" | grep -c "CODEX_HOME=$home/.n2-agents/Work/codex")" = 2
# A signed-in one signs out first: logout, login, status — each pinned.
echo '{}' > "$home/.n2-agents/Work/codex/auth.json"
out=$(run_agents login Work --vendor codex 2>&1)
test "$(print -r -- "$out" | grep -c "CODEX_HOME=$home/.n2-agents/Work/codex")" = 3
rm "$home/.n2-agents/Work/codex/auth.json"

# --- next best: no lab is anyone's default -------------------------------
# Cursor and opencode keep their logins out of sight, so a slot of theirs can
# only be taken at its word; drop theirs so every slot here is checkable.
rm -rf "$home"/.n2-agents/{Default,Work}/{cursor,opencode}
# Nothing signed in: nothing to guess.
if run_agents run >/dev/null 2>&1; then echo "run picked a slot with nothing signed in" >&2; exit 1; fi
# Commands that act on one lab ask rather than defaulting to the first.
if run_agents login Work >/dev/null 2>&1; then echo "login guessed a lab" >&2; exit 1; fi
rm -f "$home/.n2-agents/.last-slot"
echo "$codex_auth" > "$home/.n2-agents/Work/codex/auth.json"
codex_usage 10 false
echo "$grok_auth" > "$home/.n2-agents/Work/grok/auth.json"
grok_usage 10
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
# A lab at its limit is passed over, every time round.
codex_usage 100 true
out=$(run_agents run 2>&1)
[[ $out == *"GROK_HOME=$home/.n2-agents/Work/grok"* ]]
out=$(run_agents run 2>&1)
[[ $out == *"GROK_HOME=$home/.n2-agents/Work/grok"* ]]
rm "$home/.n2-agents/Work/codex/auth.json" "$home/.n2-agents/Work/grok/auth.json" "$home/.n2-agents/Work/grok/billing.json"

# --- adopt: shares claudes state, never copies it --------------------------
adopt_home="$test_root/adopt-home"
mkdir -p "$adopt_home/.claude-profiles/Default" "$adopt_home/.claude-profiles/Client"
echo token > "$adopt_home/.claude-profiles/Client/.credentials.json"
HOME="$adopt_home" PATH="$fake_path" ./agents adopt --yes >/dev/null 2>&1
# A symlink, so both apps read one login; a copy would force a re-login because
# Claude Code keys its keychain entry to the config dir path.
test -L "$adopt_home/.n2-agents/Client/claude"
test "$(readlink "$adopt_home/.n2-agents/Client/claude")" = "$adopt_home/.claude-profiles/Client"
test "$(cat "$adopt_home/.n2-agents/Client/claude/.credentials.json")" = token
# The legacy tree is untouched — `claudes` must keep working.
test -d "$adopt_home/.claude-profiles/Client"

# Adopted profiles resolve as active through the symlink indirection.
HOME="$adopt_home" PATH="$fake_path" ./agents use Client --vendor claude >/dev/null
test "$(HOME="$adopt_home" PATH="$fake_path" ./agents active --vendor claude)" = Client

# --- desktop instances and delete ------------------------------------------
desk_home="$test_root/desk-home"
desk() { HOME="$desk_home" PATH="$fake_path" ./agents "$@" }
desk new Work --vendors claude,codex >/dev/null
desk new WorkIO --vendors claude >/dev/null
support="$desk_home/Library/Application Support"
mkdir -p "$support/Claude-Work" "$support/Codex-Work" "$support/Claude-WorkIO"

# An instance is pinned by its env and told apart by its data dir.
test "$(. ./vendors.sh; vendor_desktop_env codex /slot "/data dir")" = "$(printf '%s\n' \
  CODEX_HOME=/slot "CODEX_ELECTRON_USER_DATA_PATH=/data dir" CODEX_SPARKLE_ENABLED=false)"
test "$(. ./vendors.sh; vendor_desktop_env claude /slot /data)" = CLAUDE_CONFIG_DIR=/slot

# Default must not share the stock desktop's lock or follow the active CLI
# symlink. Exercise the real launch command with a symlinked Default slot.
launch_bin="$test_root/launch-bin"
launch_home="$test_root/launch-home"
mkdir -p "$launch_bin" "$launch_home/.n2-agents/Default" \
  "$launch_home/.n2-agents/Work/codex" "$launch_home/original-codex" \
  "$test_root/Launch.app/Contents"
ln -s "$launch_home/original-codex" "$launch_home/.n2-agents/Default/codex"
ln -s "$launch_home/.n2-agents/Work/codex" "$launch_home/.codex"
cat > "$launch_bin/mdfind" <<'FAKE'
#!/bin/sh
printf '%s\n' "$FAKE_DESKTOP_APP"
FAKE
cat > "$launch_bin/open" <<'FAKE'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_DESKTOP_ARGS"
FAKE
printf '#!/bin/sh\nexit 0\n' > "$launch_bin/ps"
chmod +x "$launch_bin/mdfind" "$launch_bin/open" "$launch_bin/ps"
HOME="$launch_home" PATH="$launch_bin:$fake_path" \
  FAKE_DESKTOP_APP="$test_root/Launch.app" FAKE_DESKTOP_ARGS="$test_root/launch-args" \
  ./agents desktop Default --vendor codex
canonical_slot=$(cd -P "$launch_home/original-codex" && pwd)
grep -qxF "CODEX_HOME=$canonical_slot" "$test_root/launch-args"
grep -qxF "CODEX_ELECTRON_USER_DATA_PATH=$launch_home/Library/Application Support/Codex-Default" "$test_root/launch-args"
grep -qxF -- "--user-data-dir=$launch_home/Library/Application Support/Codex-Default" "$test_root/launch-args"

# The exact data dir, not a prefix: WorkIO open doesn't make Work look open. A
# script under a bundle-shaped path stands in for the app.
fake_app="$test_root/Fake.app/Contents/MacOS"
mkdir -p "$fake_app"
printf '#!/bin/sh\nsleep 30\n' > "$fake_app/Fake"
chmod +x "$fake_app/Fake"
"$fake_app/Fake" --user-data-dir="$support/Claude-WorkIO" &
fake_pid=$!
sleep 0.3
porcelain=$(desk porcelain)
print -r -- "$porcelain" | grep -q '^P	WorkIO	1	'
print -r -- "$porcelain" | grep -q '^P	Work	0	'
if desk delete WorkIO --yes >/dev/null 2>&1; then
  echo "A profile open in a desktop app was deleted" >&2
  exit 1
fi
kill $fake_pid
wait $fake_pid 2>/dev/null || true

out=$(desk desktop Work --vendor grok 2>&1 || true)
[[ $out == *"has no desktop app"* ]]

# Delete takes the slots and every lab's desktop data…
desk delete Work --yes >/dev/null
test ! -e "$desk_home/.n2-agents/Work"
test ! -e "$support/Claude-Work"
test ! -e "$support/Codex-Work"
test -d "$support/Claude-WorkIO"
# …except Claude data a `claudes` profile shares.
mkdir -p "$desk_home/.claude-profiles/WorkIO"
desk delete WorkIO --yes >/dev/null
test ! -e "$desk_home/.n2-agents/WorkIO"
test -d "$support/Claude-WorkIO"

# --- reserved and invalid names --------------------------------------------
for bad in As default; do
  if HOME="$test_root/names" PATH="$fake_path" ./agents new "$bad" >/dev/null 2>&1; then
    echo "Reserved profile name '$bad' was accepted" >&2
    exit 1
  fi
done
# An unknown vendor must fail loudly instead of quietly creating nothing.
if HOME="$test_root/names" PATH="$fake_path" ./agents new Nope --vendors notalab >/dev/null 2>&1; then
  echo "Unknown vendor was accepted" >&2
  exit 1
fi

# --- PATH shims ------------------------------------------------------------
shim_home="$test_root/shim-home"
shim_bin="$shim_home/.local/bin"
foreign_bin="$test_root/foreign-bin"
mkdir -p "$shim_home/.n2-agents/Client/claude" "$shim_home/.n2-agents/Client/codex" \
  "$shim_bin" "$foreign_bin" "$test_root/foreign"
ln -s /usr/bin/false "$foreign_bin/claude-client"
ln -s "$test_root/foreign/agent-as" "$shim_bin/claude-outside"
ln -s "$PWD/agents" "$shim_bin/agents"

HOME="$shim_home" PATH="/usr/bin:/bin" sh -c '
  set -- help
  . "$0" >/dev/null
  test "$(bin_dir)" = "$HOME/.local/bin"
' "$PWD/agents"
test "$(cat "$shim_home/.n2-agents/.bin-dir")" = "$shim_bin"

HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" ./agents shims >/dev/null

# Shims exist per (vendor, profile) that actually has a slot…
for name in claude-as codex-as claude-client codex-client; do
  test "$(readlink "$shim_bin/$name")" = "$PWD/shell/agent-as"
done
# …and not for vendors the profile has no slot for.
test ! -e "$shim_bin/grok-client"
# Foreign links are never clobbered.
test "$(readlink "$shim_bin/claude-outside")" = "$test_root/foreign/agent-as"

# A shim left pointing into the pre-rename N2Agents.app is ours: re-pointed.
ln -sf "/Applications/N2Agents.app/Contents/Resources/agent-as" "$shim_bin/claude-client"
HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" ./agents shims >/dev/null
test "$(readlink "$shim_bin/claude-client")" = "$PWD/shell/agent-as"

# A retired lab (Gemini) leaves nothing of ours behind: its shims go, and its
# dot dir stops being a symlink into a profile slot but keeps the contents.
mkdir -p "$shim_home/.n2-agents/Client/gemini"
echo keep > "$shim_home/.n2-agents/Client/gemini/settings.json"
ln -s "$shim_home/.n2-agents/Client/gemini" "$shim_home/.gemini"
ln -s "$PWD/shell/agent-as" "$shim_bin/gemini-client"
HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" ./agents shims >/dev/null
test ! -e "$shim_bin/gemini-client"
test ! -L "$shim_home/.gemini"
test "$(cat "$shim_home/.gemini/settings.json")" = keep

# Concurrent syncs must not leave the lock behind.
HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" TMPDIR="$test_root/one" ./agents shims >/dev/null &
first=$!
HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" TMPDIR="$test_root/two" ./agents shims >/dev/null &
second=$!
wait $first
wait $second
test ! -e "$shim_home/.n2-agents/.shims.lock"

# A shim dispatches to the right vendor: the name carries both halves.
HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" "$shim_bin/codex-client" \
  | grep -q "CODEX_HOME=$shim_home/.n2-agents/Client/codex"

HOME="$shim_home" PATH="$fake_bin:$shim_bin:/usr/bin:/bin" ./agents shims --remove >/dev/null
test ! -e "$shim_bin/claude-client"
test "$(readlink "$shim_bin/claude-outside")" = "$test_root/foreign/agent-as"

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

# --- loop ------------------------------------------------------------------
# Pure logic first: reports, failure classes, paths, slot picking, plan
# validation, and what "done" means.
loop_unit=$(mktemp -d "$TMPDIR/loopunit.XXXXXX")/loop-tests
swiftc -parse-as-library ${(f)"$(ls loop/*.swift | grep -v main.swift)"} tests/LoopTests.swift -o "$loop_unit"
"$loop_unit"

# Then end to end: the real CLI, real git and the real engine, with a fake
# agent playing every role (tests/fake-loop-agent.sh) on two Codex slots.
# The package also contains the tray app and its Sparkle dependency. Compile
# the standalone loop executable directly so this test doesn't resolve the
# app's binary resources just to exercise the loop engine.
mkdir -p .build/release
swiftc -swift-version 5 -O loop/*.swift -o "$PWD/.build/release/n2-loop"
n2_root=$PWD
loop_root="$test_root/loop"
mkdir -p "$loop_root/home" "$loop_root/bin"
cp tests/fake-loop-agent.sh "$loop_root/bin/codex"
cp tests/fake-loop-protocol.py "$loop_root/bin/fake-loop-protocol.py"
cp "$fake_bin/security" "$loop_root/bin/security"
chmod +x "$loop_root/bin/codex"
printf '{"rate_limit": {"limit_reached": false, "primary_window": {"used_percent": 10, "limit_window_seconds": 604800, "reset_at": 1790411072}, "secondary_window": null}}' \
  > "$loop_root/usage.json"
loop_env=(LOOP_FAKE_STRUCTURED=1 HOME="$loop_root/home" PATH="$loop_root/bin:/usr/bin:/bin" N2_LOOP_HOME="$loop_root/runs"
          N2_CODEX_USAGE_URL="file://$loop_root/usage.json")
for p in Work Home; do
  env $loop_env ./agents new $p --vendors codex >/dev/null 2>&1
  echo "$codex_auth" > "$loop_root/home/.n2-agents/$p/codex/auth.json"
done
loop() { env $loop_env LOOP_FAKE="$loop_fake" "$n2_root/agents" loop "$@" }
field() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$loop_root/runs/$run/state.json" "$1" }
wait_for() {  # status
  for _ in {1..300}; do [ "$(field 's["status"]')" = "$1" ] && return 0; sleep 0.2; done
  echo "loop never reached $1:" >&2; loop status "$run" >&2; cat "$loop_root/runs/$run/controller.log" >&2; return 1
}
# A fresh repository and scenario, planned and approved the way a person would.
new_loop() {  # scenario files…
  # Each scenario starts after a synthetic successful invocation on the fixture
  # routes. Real rejections intentionally survive new loop runs now.
  fixture_recovery=$(python3 -c 'import json,time; print(json.dumps({"status":"ok","source":"test-fixture","startedAt":time.time()}))')
  for fixture_profile in Home Work Q1 Q2 Q3 Q4 Q5; do
    if [ -d "$loop_root/home/.n2-agents/$fixture_profile/codex" ]; then
      env $loop_env "$n2_root/agents" usage record --provider codex --profile "$fixture_profile" \
        --kind execution-succeeded --data "$fixture_recovery" >/dev/null
    fi
  done
  loop_fake=$(mktemp -d "$loop_root/fake.XXXXXX")
  for f in "$@"; do  # name, or name=contents
    case $f in *=*) echo "${f#*=}" > "$loop_fake/${f%%=*}" ;; *) touch "$loop_fake/$f" ;; esac
  done
  repo=$(mktemp -d "$loop_root/repo.XXXXXX")
  git -C "$repo" init -q && git -C "$repo" config user.email loop@test && git -C "$repo" config user.name Loop
  echo hi > "$repo/README" && git -C "$repo" add . && git -C "$repo" commit -qm init
  loop plan "write a and b" --budget 1h --cwd "$repo" >/dev/null
  run=$(ls -t "$loop_root/runs" | head -1)
  loop approve "$run" >/dev/null
}

# Fan out, review, merge, verify, sign off: the result lands on the run's
# branch and the user's checkout never changes.
new_loop
wait_for DONE
branch="n2/loop-${run[1,8]}"
git -C "$repo" show "${branch}:a.txt" | grep -q done
git -C "$repo" show "${branch}:b.txt" | grep -q done
[ ! -e "$repo/a.txt" ] && [ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" != "$branch" ]
[ "$(git -C "$repo" worktree list | wc -l | tr -d ' ')" = 1 ]      # scaffolding cleared away
test -f "$loop_root/runs/$run/DONE.md"
roles=$(field '" ".join(sorted(set(t["role"] for t in s["turns"])))')
[ "$roles" = "planner supervisor verifier worker" ]
shown=$(loop status "$run")
[[ $shown == *"DONE"* && $shown == *"✓ has-a"* && $shown == *"✓ grep -q done b.txt"* ]]
loop list | grep -q "${run[1,8]}  DONE"

# A slot out of quota costs the work nothing: planning and chunks fail over.
new_loop quota-Home
wait_for DONE
[ "$(field 'len([t for t in s["turns"] if t["outcome"] == "quota" and t["slot"] == "codex|Home"])')" -ge 1 ]
env $loop_env "$n2_root/agents" usage history > "$loop_root/usage-history.json"
python3 - "$loop_root/usage-history.json" "$run" <<'PYTEST'
import json,sys
events=json.load(open(sys.argv[1]))
matched=[e for e in events if e['kind']=='quota-rejected' and e['data'].get('attribution',{}).get('task','').startswith(sys.argv[2]+'/')]
assert matched and matched[0]['profile']=='Home'
assert matched[0]['data']['identity']['status']=='unknown'
assert matched[0]['data']['resetKnown'] is False, 'timezone-free date is only a local retry hint'
assert matched[0]['data']['recheckAt'] is None
assert matched[0]['data']['attribution']['totalTokens'] is None
successes=[e for e in events if e['kind']=='execution-succeeded' and e['data'].get('attribution',{}).get('task','').startswith(sys.argv[2]+'/')]
assert successes and successes[0]['data']['attribution']['totalTokens']==60
assert successes[0]['data']['attribution']['cachedInputTokens']==30
assert successes[0]['data']['session'].startswith('fixture-')
PYTEST
# The fresh reader must report the persisted rejection even though the fake
# allowance endpoint continues to report headroom.
env $loop_env "$n2_root/agents" best --json --vendor codex > "$loop_root/effective-usage.jsonl"
python3 - "$loop_root/effective-usage.jsonl" <<'PYTEST'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1])]
home=next(row for row in rows if row['profile']=='Home')
assert home['status']=='restricted'
assert any(r['reason']=='quota-rejected' for r in home['restrictions'])
PYTEST
[ "$(field 's["cooldowns"]["codex|Home"]["until"][:4]')" = 2099 ]   # the reset time the lab stated
[ "$(field '{c["lastSlot"] for c in s["plan"]["chunks"]}')" = "{'codex|Work'}" ]
[ "$(field 'max(c["revisions"] for c in s["plan"]["chunks"])')" = 0 ]

# Every slot running dry waits for the stated reset and carries on by itself —
# however many quota failures that takes, it never turns into a pause.
new_loop worker-quota-Home=4 worker-quota-Work=4
wait_for DONE
[ "$(field 'len([t for t in s["turns"] if t["outcome"] == "quota"])')" = 8 ]
field '[e["detail"] for e in s["events"] if e["kind"] == "capacity"]' | grep -q "out of quota or cooling down; retrying at"
[ "$(field 'len([e for e in s["events"] if e["kind"] == "paused"])')" = 0 ]

# Pause stops running agents at once and keeps their work; resume finishes.
new_loop slow
for _ in {1..100}; do [ "$(field 'len([t for t in s["turns"] if t["role"] == "worker" and not t.get("endedAt") and t.get("pgid")])')" = 2 ] && break; sleep 0.2; done
pgids=(${(f)"$(field '"\n".join(str(t["pgid"]) for t in s["turns"] if t["role"] == "worker")')"})
loop pause "$run" >/dev/null
[ "$(field 's["status"]')" = PAUSED ]
[[ "$(field 's["reason"]')" == "paused by you"* ]]
[ "$(field '{t["outcome"] for t in s["turns"] if t["role"] == "worker"}')" = "{'interrupted'}" ]
for g in $pgids; do ! kill -0 -"$g" 2>/dev/null; done
rm "$loop_fake/slow"
loop resume "$run" >/dev/null
wait_for DONE
[ "$(field 'min(c["turns"] for c in s["plan"]["chunks"])')" = 2 ]

# Done means the definition of done: a criterion the verifier rejects sends
# its chunk back, and only a fresh pass on the new commit finishes the run.
new_loop fail-b-once
wait_for DONE
[ "$(field 'len([e for e in s["evidence"] if e["criterion"] == "has-b" and not e["passed"]])')" = 1 ]
[ "$(field '[c["revisions"] for c in s["plan"]["chunks"]]')" = "[0, 1]" ]
[ "$(field 's["evidence"][-1]["candidate"] == s["lastMerge"] and all(e["passed"] for e in s["evidence"] if e["candidate"] == s["lastMerge"])')" = True ]

# …and a supervisor who calls it done anyway is overruled.
new_loop fail-b-once liar
wait_for PAUSED
[[ "$(field 's["reason"]')" == *"doesn't hold"* ]]

# More than four exhausted slots must not hide the healthy planner after them.
for p in Q1 Q2 Q3 Q4 Q5; do
  env $loop_env ./agents new $p --vendors codex >/dev/null 2>&1
  echo "$codex_auth" > "$loop_root/home/.n2-agents/$p/codex/auth.json"
done
new_loop quota-Home quota-Q1 quota-Q2 quota-Q3 quota-Q4 quota-Q5
wait_for DONE
[ "$(field 'len([t for t in s["turns"] if t["role"] == "planner" and t["outcome"] == "quota"])')" -ge 5 ]

run_agents help | grep -Fq 'agents loop "goal"'

sh scripts/test-usage.sh
python3 scripts/test-bound-planner.py
python3 scripts/test-profile-metadata.py

echo "All tests passed"
