#!/bin/sh
# Synthetic provider executables exercise argv, stdin and profile isolation.
# This does not exercise provider authentication or spend provider tokens.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2prompt.XXXXXX")
trap 'rm -rf "$base"' EXIT
. "$repo/vendors.sh"
. "$repo/fleet-exec.sh"
export HOME="$base/home"
mkdir -p "$base/bin" "$base/spec" "$HOME/Work/claude" "$HOME/Work/codex"
export PATH="$base/bin:$PATH" N2_PROMPT_CAPTURE="$base/capture"
active_profile() { echo Work; }
config_dir() { echo "$HOME/$1/$2"; }
cat > "$base/bin/claude" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$N2_PROMPT_CAPTURE.args"
printf '%s\n' "${CLAUDE_CONFIG_DIR:-}" > "$N2_PROMPT_CAPTURE.env"
cat > "$N2_PROMPT_CAPTURE.stdin"
exit "${N2_PROMPT_EXIT:-0}"
SH
cp "$base/bin/claude" "$base/bin/codex"
sed 's/CLAUDE_CONFIG_DIR/CODEX_HOME/' "$base/bin/claude" > "$base/bin/codex"
chmod +x "$base/bin/claude" "$base/bin/codex"
printf 'Implement this\nwith two lines; $(touch NEVER)\n' > "$base/spec/command"
printf 'Keep the existing API.\n' > "$base/spec/context"
exec_invoke_prompt claude "$base/spec"
test "$(cat "$base/capture.args")" = --print
test "$(cat "$base/capture.env")" = "$HOME/Work/claude"
grep -Fq 'with two lines; $(touch NEVER)' "$base/capture.stdin"
grep -Fq 'Keep the existing API.' "$base/capture.stdin"
test ! -e NEVER
echo 'ok Claude receives literal multiline prompt and context in isolated profile'
exec_invoke_prompt codex "$base/spec"
test "$(cat "$base/capture.args")" = "$(printf 'exec\n-')"
test "$(cat "$base/capture.env")" = "$HOME/Work/codex"
echo 'ok Codex receives stdin prompt and isolated profile'
if exec_invoke_prompt cursor "$base/spec" 2>/dev/null; then exit 1; fi
echo 'ok unsupported provider refuses prompt invocation'
export N2_PROMPT_EXIT=23
if exec_invoke_prompt claude "$base/spec"; then exit 1; else test "$?" = 23; fi
echo 'ok provider failure remains a failed invocation'
unset N2_PROMPT_EXIT
rm -rf "$HOME/Work/codex"
if exec_invoke_prompt codex "$base/spec" 2>/dev/null; then exit 1; fi
echo 'ok missing active profile refuses invocation'
