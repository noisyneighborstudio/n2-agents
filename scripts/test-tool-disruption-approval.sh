#!/bin/sh
# Signed isolated replication must not change locally approved disruption policy.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d /private/tmp/n2-tool-disruption.XXXXXX)
trap 'echo "Isolated fixture retained: $base"' EXIT
mkdir -p "$base/runtime" "$base/bin" "$base/tmp"
# Copy only runtime sources; never activate a live packaged QA root selector.
git -C "$repo" ls-files | while IFS= read -r file; do
  case $file in */*) continue;; agents|*.sh|*.py) cp "$repo/$file" "$base/runtime/$file";; esac
done
printf '#!/bin/sh\nexit 1\n' > "$base/bin/security"
chmod +x "$base/bin/security"
cat > "$base/agents" <<EOF_WRAPPER
#!/bin/sh
case "\$HOME" in "$base"/remove/*|"$base"/add/*) ;; *) exit 97;; esac
export N2_AGENTS_ROOT="\$HOME/.n2-agents" N2_FLEET_AGENTS="$base/agents"
export PATH="$base/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$base/tmp"
exec "$base/runtime/agents" "\$@"
EOF_WRAPPER
chmod +x "$base/agents"
peer() { tool_home=$1; shift; env -i HOME="$case_root/$tool_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$base/agents" "$@"; }
check='printf checked >> "$HOME/checks"; cat "$HOME/version"'
install='printf installed >> "$HOME/installs"; cp "$HOME/want" "$HOME/version"'
expect() { case $1 in *"$2"*) ;; *) printf 'FAIL expected %s in %s\n' "$2" "$1"; exit 1;; esac; }
no_commands() { [ ! -e "$case_root/beta/checks" ] && [ ! -e "$case_root/beta/installs" ]; }
clear_markers() { rm -f "$case_root/beta/checks" "$case_root/beta/installs"; }
for direction in remove add; do
  case_root="$base/$direction"
  mkdir -p "$case_root/alpha" "$case_root/beta"
  peer alpha fleet init --machine alpha >/dev/null
  beta=$(peer beta fleet init --machine beta | awk '{print $2}')
  peer beta fleet pair --home "$case_root/alpha" \
    --code "$(peer alpha fleet invite --peer "$beta")" >/dev/null
  peer alpha fleet sync now --peer "$beta" > "$case_root/baseline-sync"
  before=; after=--disruptive
  if [ "$direction" = remove ]; then before=--disruptive; after=; fi
  peer alpha fleet tools add widget --version 1 --check "$check" --install "$install" $before >/dev/null
  peer alpha fleet sync now --peer "$beta" > "$case_root/initial-sync"
  peer beta fleet tools approve widget >/dev/null
  printf 1 > "$case_root/beta/want"
  peer beta fleet tools install widget >/dev/null
  [ "$(cat "$case_root/beta/version")" = 1 ]
  clear_markers
  active="$case_root/beta/.n2-agents/fleet/tasks/active"
  mkdir -p "$active"
  printf 'pid %s\n' "$$" > "$active/fixture"
  printf 2 > "$case_root/beta/want"
  # Commands are unchanged. Only the replicated version and flag change.
  peer alpha fleet tools add widget --version 2 --check "$check" --install "$install" $after >/dev/null
  peer alpha fleet sync now --peer "$beta" > "$case_root/changed-sync"
  listing=$(peer beta fleet tools list)
  printf '%s classification changed: %s\n' "$direction" "$listing"
  # Print actual side effects before asserting, so the negative control is clear.
  for marker in checks installs; do
    if [ -f "$case_root/beta/$marker" ]; then printf '%s: %s\n' "$marker" "$(cat "$case_root/beta/$marker")"; fi
  done
  expect "$listing" pending-approval
  no_commands
  expect "$(peer beta fleet tools apply)" pending-approval
  if peer beta fleet tools install widget > "$case_root/refusal" 2>&1; then
    echo 'FAIL named install accepted unapproved policy'; exit 1
  fi
  expect "$(cat "$case_root/refusal")" pending-approval
  no_commands
  [ "$(cat "$case_root/beta/version")" = 1 ]
  # Renewed local consent permits the new classification, preserving deferral.
  peer beta fleet tools approve widget >/dev/null
  if [ -n "$after" ]; then
    expect "$(peer beta fleet tools apply)" deferred
    expect "$(peer beta fleet tools install widget)" deferred
    [ ! -f "$case_root/beta/installs" ]
    rm "$active/fixture"
  fi
  peer beta fleet tools install widget >/dev/null
  [ "$(cat "$case_root/beta/version")" = 2 ]
  # Version-only replication retains consent, including active-work deferral.
  printf 'pid %s\n' "$$" > "$active/fixture"
  printf 3 > "$case_root/beta/want"
  clear_markers
  peer alpha fleet tools add widget --version 3 --check "$check" --install "$install" $after >/dev/null
  peer alpha fleet sync now --peer "$beta" > "$case_root/version-sync"
  listing=$(peer beta fleet tools list)
  case $listing in *pending-approval*) echo 'FAIL version-only update lost approval'; exit 1;; esac
  if [ -n "$after" ]; then
    expect "$(peer beta fleet tools apply)" deferred
    expect "$(peer beta fleet tools install widget)" deferred
    [ ! -f "$case_root/beta/installs" ]
  fi
  rm "$active/fixture"
  peer beta fleet tools apply >/dev/null
  [ "$(cat "$case_root/beta/version")" = 3 ]
  # Legacy command-only approvals have no evidence of local disruption consent.
  manifest="$case_root/beta/.n2-agents/fleet/tools/manifest"
  legacy=$(printf '%s\n%s\n' "$(cut -d'|' -f4 "$manifest")" "$(cut -d'|' -f3 "$manifest")" | shasum -a 256 | cut -c1-32)
  printf 'widget|%s\n' "$legacy" > "$case_root/beta/.n2-agents/fleet/tools/approved"
  clear_markers
  expect "$(peer beta fleet tools apply)" pending-approval
  if peer beta fleet tools install widget > "$case_root/legacy-refusal" 2>&1; then
    echo 'FAIL legacy approval accepted'; exit 1
  fi
  no_commands
  peer beta fleet tools approve widget >/dev/null
  expect "$(peer beta fleet tools install widget)" ok
  echo "ok $direction: classification consent, version-only update, legacy refusal and renewed approval"
done
