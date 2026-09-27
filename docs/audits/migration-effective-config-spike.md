# Logout configuration observation spike

This bounded experiment checks whether available read-only Codex interfaces prove
which credential storage and provider route CLI logout will use. It does not.
The [fixture](migration-effective-config-spike.json) retains source fingerprints,
inputs described below and projected observations from installed Codex 0.157.1.

## Proof and observations

Each case used a fresh temporary HOME and CODEX_HOME, a minimal environment,
`features.secret_auth_storage=false`, and macOS `sandbox-exec` with
`(version 1)(allow default)(deny network*)`. No credentials were supplied.
The probe ran `codex features list`, then a fresh `codex app-server`, initialized
JSON-RPC, and requested `config/read` with the temporary cwd and `includeLayers=false`,
followed by `configRequirements/read`. It waited on pipe readiness with bounded
timeouts, closed stdin, and waited for the server to exit. No sleeps were used.

| Input in config.toml | config/read result | features list |
| --- | --- | --- |
| Store omitted | file | secret_auth_storage false |
| cli_auth_credentials_store="file" | file | secret_auth_storage false |
| cli_auth_credentials_store="ephemeral" | ephemeral | secret_auth_storage false |
| file store plus legacy profile="test" and profiles.test | unsupported legacy profile error | exit 1 |

All four final assertion cases passed. Each requirements response was null, and
none of the cases created auth.json. The legacy profile set model_provider="ollama"
inside profiles.test. The error instructs callers to use --profile with a separate
profile config file; that alternative was not tested. Initial assumptions that
legacy profiles would work and omitted storage would serialize as null were
contradicted, corrected in the experiment, and retained here rather than treated
as product defects. No logout or model turn ran. No credentials were supplied;
OS Keychain access was not instrumented or excluded by this sandbox.

## Source comparison

The [official app-server documentation](https://learn.chatgpt.com/docs/app-server)
describes configuration inspection. The
[configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
describes managed storage constraints. Neither promises that a separate read RPC
is a receipt of the configuration a later CLI logout will use.

Pinned OpenAI source at `36650394c5b38c2990ccf2a3457165ca3e9d9726` establishes:

- `app-server/src/config_manager_service.rs` merges config layers into ConfigToml,
  applies exact requirements and serializes that structure. It does not serialize
  the complete resolved runtime Config object.
- `cli/src/main.rs` uses `cli/src/cloud_config.rs` for features list. That loader
  builds authentication for fetching cloud configuration before building Config.
- `cli/src/login.rs` uses Config::load_with_cli_overrides for logout. In
  `core/src/config/mod.rs`, that method starts with the default ConfigBuilder.
  These are distinct loading paths; agreement under the empty synthetic setup
  does not establish equivalence under cloud policy.
- `core/src/config/auth_keyring.rs` chooses the backend using the full Config's
  effective SecretAuthStorage feature.
- After auth cleanup, CLI logout can clear Bedrock model/provider/AWS settings.
  `core/src/config/edit/bedrock.rs` limits this to selected Bedrock providers that
  match the active user config layer. It is an additional mutation to account for.

The fixture lists exact source paths and hashes under the canonical
[OpenAI repository revision](https://github.com/openai/codex/tree/36650394c5b38c2990ccf2a3457165ca3e9d9726).
The experiment does not prove managed MDM/system/cloud behavior, binary provenance,
Keychain cleanup or provider revocation. The exploratory runner is discarded after
review; only observations and notes are retained.

## Decision and next work

Do not implement general migration logout by treating config/read plus features
list as a verified snapshot of CLI logout configuration. The logout slice remains
required, with a prerequisite to establish a same-operation, provider-supported
configuration observation or another verified way to bind the cleanup scope.
Bedrock configuration changes must be explicitly covered or refused.

Move native session transfer ahead of this unresolved integration work. Its brief
already has a verified CLI underneath it and can deliver a visible product action.
This ordering does not complete or waive migration, Keychain, peer retirement,
activation or live-provider acceptance requirements.
