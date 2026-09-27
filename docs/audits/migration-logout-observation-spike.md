# Logout scope observation: remaining provider capability

This spike follows the inconclusive separate-config-read experiment. It tests
whether explicit CLI configuration can instead fix logout's scope. It cannot
provide that guarantee under managed policy. No real logout, credential access,
provider binary or network operation ran in the fixture.

## Proof

Eight assertions passed using unchanged source extracted from OpenAI revision
`36650394c5b38c2990ccf2a3457165ca3e9d9726`. The retained
[fixture](migration-logout-observation-spike.json) records source fingerprints
and outputs. A temporary Rust executable compiled the storage-selection
expression, its local-build resolver, and the Bedrock path-selection method.
Synthetic config and layer types replace the full configuration loader. This
proves the extracted decisions, not installed-binary or managed-policy acceptance.

| Configured store | Required store | Selected store |
| --- | --- | --- |
| file | absent | file |
| file | keyring | keyring |
| ephemeral | auto | auto |
| keyring | file | file |

The [runtime Config constructor](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/core/src/config/mod.rs)
selects a requirement's value before the configured mode. A conflicting CLI
storage option therefore cannot be assumed to refuse before mutation.

Four additional cases exercised the unchanged
[Bedrock path selector](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/core/src/config/edit/bedrock.rs).
Matching Bedrock and Bedrock-runtime selections each return three paths for
cleanup: model provider, that provider's AWS settings, and model. OpenAI selection
and a differing active user-layer provider return no paths. No files were edited.

## Same-process RPC is insufficient

The [account protocol](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/app-server-protocol/src/protocol/v2/account.rs)
returns an empty logout response. Account reads identify account and workspace
routing, not credential store or cleanup scope.

The [logout handler](https://github.com/openai/codex/blob/36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/app-server/src/request_processors/account_processor.rs)
loads latest configuration, invokes the existing auth manager's logout, and may
clear Bedrock settings. Keeping an app-server alive does not make a preceding
configuration RPC an atomic scope receipt. This source finding is not a claim
that configuration changed during an observed live logout.

## Decision and bounded alternative

The examined interfaces do not supply the required same-operation scope receipt.
Do not implement general migration logout from a separate snapshot or forced
CLI storage values. Do not silently replace it with file-only cleanup.

The missing capability is a provider-supported prepare/execute contract that
reports the resolved canonical home, store/backend, auth route and configuration
paths, then refuses execution if that scope changed. Execution must distinguish
local cleanup from provider revocation and return partial outcomes. Equivalent
same-operation provider instrumentation would also need acceptance evidence.
N2 must not invent such a receipt from an empty provider response.

A bounded next integration step is to establish this capability with the provider
before implementing the queued migration operation. No provider change or
external contribution is made by this spike. Existing migration stays fenced;
Keychain retirement, peer cleanup, fresh owner activation and live lifecycle
acceptance remain required. Native refresh/notification acceptance can proceed
independently. The exploratory executable and runner are discarded after review;
only this note and the fixture are retained in the repository.
