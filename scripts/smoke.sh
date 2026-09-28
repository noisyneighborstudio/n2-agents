#!/bin/sh
# Real CLI against disposable homes: synthetic providers and a signed
# synthetic owner; no provider calls.
set -eu
cd "$(dirname "$0")/.."
(
smoke_root=$(mktemp -d)
trap 'rm -rf "$smoke_root"' EXIT HUP INT TERM
mkdir -p "$smoke_root/home/.n2-agents/Fixture/codex" "$smoke_root/bin"
cat > "$smoke_root/bin/codex" <<'PROVIDER'
#!/bin/sh
printf '%s\n' "$CODEX_HOME"
PROVIDER
chmod +x "$smoke_root/bin/codex"
export HOME="$smoke_root/home" PATH="$smoke_root/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset CODEX_HOME CLAUDE_CONFIG_DIR OPENAI_API_KEY
./agents help > "$smoke_root/help"
grep -Fq 'agents loop' "$smoke_root/help"
./agents run Fixture --vendor codex --version > "$smoke_root/route"
test "$(cat "$smoke_root/route")" = "$HOME/.n2-agents/Fixture/codex"
)
echo 'Smoke: real CLI routes to isolated profile.'
# The behaviors a real run depends on (AGENTS.md "Smoke run"). Full suites run
# in scripts/test.sh; smoke repeats none of them.
python3 scripts/test-fleet-auth-bridge.py \
  BridgeIntegrationTests.test_n2_session_browser_and_resume_discover_original_profile \
  BridgeIntegrationTests.test_killed_record_publisher_recovers_in_discovery_and_resume \
  BridgeIntegrationTests.test_record_recovery_refuses_unrecognized_hardlinks \
  BridgeIntegrationTests.test_capitalized_vendor_resumes_saved_session \
  BridgeIntegrationTests.test_existing_session_with_duplicate_or_missing_profile_never_falls_back \
  BridgeIntegrationTests.test_session_discovery_does_not_hide_corrupt_or_foreign_bindings \
  TerminalLifetimeTests

python3 scripts/test-fleet-auth-transport.py \
  TransportTests.test_descendant_inheriting_stdout_is_reaped

python3 scripts/test-fleet-auth-migration.py \
  MigrationTests.test_archive_roundtrip_preserves_pending_and_conflict_bytes \
  MigrationTests.test_archive_and_restore_reconcile_interrupted_publication \
  MigrationTests.test_peer_preparation_requires_consent_and_preserves_legacy_bytes \
  MigrationTests.test_lost_reply_keeps_coordinator_pending_without_fabricating_acknowledgement \
  MigrationTests.test_coordinated_abandon_waits_for_peers_and_rejects_late_prepare

exec python3 scripts/test-codex-rpc.py ParentLifetimeTests
