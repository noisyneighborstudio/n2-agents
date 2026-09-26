#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d)
trap 'rm -rf "$base"' EXIT
peer() { h=$1; shift; HOME="$base/$h" N2_FLEET_AGENTS="$repo/agents" "$repo/agents" "$@"; }
mkdir -p "$base/a" "$base/b"
a=$(peer a fleet init --machine a | cut -f2)
b=$(peer b fleet init --machine b | cut -f2)
peer b fleet pair --home "$base/a" --code "$(peer a fleet invite --peer "$b" 2>/dev/null)" >/dev/null
# Both directions must file pins by the peer alias, including the approving
# side. The sender's hostname differs from its Tailscale name in a real fleet.
for h in a b; do
  if [ -f "$base/$h/.n2-agents/fleet/known_hosts" ]; then
    if grep -v '^n2-peer-\|^n2-bootstrap ' "$base/$h/.n2-agents/fleet/known_hosts" | grep -q .; then
      echo 'Enrollment stored a hostname instead of a peer host-key alias'; exit 1
    fi
  fi
done
for h in a b; do peer "$h" fleet sync auth enable codex >/dev/null 2>&1; done
slot="$base/a/.n2-agents/Work/codex"
other="$base/b/.n2-agents/Work/codex"
mkdir -p "$slot/skills/demo"
printf 'model="fixture"\n' > "$slot/config.toml"
printf 'synthetic skill\n' > "$slot/skills/demo/SKILL.md"
printf '{"tokens":{"access_token":"synthetic-only"}}\n' > "$slot/auth.json"
peer a fleet sync now >/dev/null
cmp "$slot/auth.json" "$other/auth.json"
for category in settings skills auth; do peer b fleet sync categories "$category" off >/dev/null; done
printf 'model="changed"\n' > "$slot/config.toml"
printf 'changed skill\n' > "$slot/skills/demo/SKILL.md"
printf '{"tokens":{"access_token":"synthetic-changed"}}\n' > "$slot/auth.json"
peer a fleet sync now >/dev/null
peer b fleet sync now >/dev/null
grep -q fixture "$other/config.toml"
grep -q 'synthetic skill' "$other/skills/demo/SKILL.md"
grep -q synthetic-only "$other/auth.json"
grep -q changed "$slot/config.toml"
for category in settings skills auth; do peer b fleet sync categories "$category" on >/dev/null; done
peer a fleet sync now >/dev/null
cmp "$slot/auth.json" "$other/auth.json"
cmp "$slot/config.toml" "$other/config.toml"
cmp "$slot/skills/demo/SKILL.md" "$other/skills/demo/SKILL.md"
if peer a profiles | grep -qx fleet; then echo 'fleet state exposed as profile'; exit 1; fi
mkdir -p "$base/bundle" "$base/qa/.n2-agents/Primary/codex"
cp "$repo/agents" "$repo/workspace-pack.py" "$repo/usage.py" "$repo/codex-rpc.py" "$repo/codex-run.py" "$repo/usage-store.py" "$repo/vendors.sh" "$repo/fleet.sh" "$repo/fleet-sync.sh" "$repo/fleet-exec.sh" "$repo/fleet-qa-import.py" "$repo/profile-metadata.py" "$repo/fleet-auth-response.py" "$repo/fleet-auth-transport.py" "$repo/fleet-auth-owner.py" "$repo/fleet-auth-native.py" "$repo/fleet-auth-server.py" "$repo/fleet-auth-binding.py" "$repo/fleet-auth-client.py" "$base/bundle/"
touch "$base/bundle/fleet-qa"
printf 'original' > "$base/qa/.n2-agents/Primary/codex/config.toml"
HOME="$base/qa" "$base/bundle/agents" fleet sync import-local >/dev/null
test -f "$base/qa/.n2-agents-qa/Primary/codex/config.toml"
printf 'QA change' > "$base/qa/.n2-agents-qa/Primary/codex/config.toml"
grep -qx original "$base/qa/.n2-agents/Primary/codex/config.toml"
for verb in use login shims new delete desktop run adopt; do
  if HOME="$base/qa" "$base/bundle/agents" "$verb" Primary > /dev/null 2>&1; then
    echo "QA allowed disruptive verb: $verb"; exit 1
  fi
done
printf 'Fleet spike: category opt-out/re-enable, credentials, skill sync, QA isolation and command guards passed\n'
