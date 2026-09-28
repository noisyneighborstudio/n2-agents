# Claude credential fallback evidence

## Question and proof

Does N2 select the same store-backed OAuth credential as Claude Code when a
successful primary read contains no OAuth login but a fallback file has one?
The proof compares the installed provider's exact store combiner and synchronous
OAuth accessor with N2's actual reader using synthetic, conflicting stores.
No provider process, Keychain query, renewal or network request ran.

## Canonical sources

[Claude authentication documentation](https://code.claude.com/docs/en/authentication)
describes macOS Keychain storage, file fallback when a write fails, and profile
isolation through CLAUDE_CONFIG_DIR. It does not specify read-error precedence.

The provider-distributed Claude Code 2.1.283 binary supplies the executable
read semantics. The fixture records its SHA-256 and byte offsets/hashes for the
extracted functions. The extracted Ns combiner selects any non-null primary
object. QF reads its claudeAiOauth field and returns no OAuth credential when
that field has no access token. It does not retry the fallback file.

## Observations

With environment and file-descriptor credentials absent and alternate modes
inactive, the exact accessor/combiner composition produced:

| Primary result | Provider OAuth selection | N2 before repair |
| --- | --- | --- |
| Empty object | None | File credential |
| Non-OAuth object | None | File credential |
| OAuth object with access token | Primary | Primary |
| Absent primary | File | Not compared in this probe |

The combiner's strict asynchronous read also distinguishes failure from absence
and honors an inaccessibleAs policy. The eight combiner fixtures preserve these
results. They do not justify applying one exit-code policy to every caller.

An independent supervisor verified the binary/excerpt hashes and independently
reran the four accessor cases and N2 selection. Exploratory runners were removed;
canonical excerpts and observations were retained in the isolated spike folder.
The committed fixture contains synthetic results and provenance, not credentials.

## Limits and next proof

The plaintext transformation was stubbed as identity. This proves the tested
OAuth store selection, not all provider routing or the historical M4 incident.
The narrow regression should prevent field-based fallback after a successful
primary object read while preserving absent-primary behavior. Malformed data,
read errors, cached credentials and other callers need separate evidence.

Source inspection also found that the provider supplies a validated account
selector to security and normalizes its storage path to NFC; N2 does neither.
These observations need their own selection fixtures before a repair. They do
not by themselves establish a real user's execution account.

## Regression

`python3 scripts/test-usage-reader.py ReaderTests.test_claude_primary_store_prevents_field_fallback`
failed against the prior reader for both empty and non-OAuth primary objects.
The repair changes only the field-based fallback condition. The test consumes
the recorded accessor selections, checks actual JSON/TSV output with no network,
and preserves valid-primary and existing exits 1/44 fallback behavior.
