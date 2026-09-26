#!/bin/sh
# Real CLI, private HOME/root and signed synthetic owner; no provider calls.
set -eu
cd "$(dirname "$0")/.."
exec python3 scripts/test-fleet-auth-bridge.py \
  BridgeIntegrationTests.test_n2_session_browser_and_resume_discover_original_profile \
  BridgeIntegrationTests.test_capitalized_vendor_resumes_saved_session \
  BridgeIntegrationTests.test_existing_session_with_duplicate_or_missing_profile_never_falls_back \
  BridgeIntegrationTests.test_session_discovery_does_not_hide_corrupt_or_foreign_bindings
