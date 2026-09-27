# Claude Keychain selector evidence

## Proof before repair

Exact functions from the provider-distributed Claude Code 2.1.283 binary ran
against synthetic environment, OS-user, cache and command implementations.
The fixture records source offsets/hashes, emitted query and selected names.
No real Keychain, credentials, provider process or network request was used.

The provider queries both service and account. Its account is USER when nonempty,
otherwise the OS username; invalid names and OS lookup failure use
claude-code-user. A duplicate-service fixture admits two records under N2's old
query and one under the provider query. This establishes broader constraints,
not actual Keychain enumeration order or the historical M4 failure.

The [Node OS contract](https://nodejs.org/api/os.html#osuserinfooptions) specifies
the effective user for userInfo. N2's fallback must therefore use effective UID,
not getpass environment precedence.

For an explicit secure-storage directory, the provider normalizes to NFC before
hashing. The decomposed-path fixture produces a different service under the old
reader. Default path resolution and alternate OAuth suffixes were stubbed and
remain outside this proof. Do not generalize this fixture to those routes.

Independent review verified source hashes and reran the selector/query probes.
Additional exact-selector cases cover empty USER, OS lookup failure and newline
names. Exploratory runners were discarded; canonical excerpts and observations
remain in the isolated spike directory.

## Regression and limits

The reader regression uses the retained selectors with conflicting synthetic
Keychain records and checks the actual credential selected by claude_creds.
It covers explicit decomposed paths and username fallback/validation. Existing
credential overrides, primary-store precedence and read-error policy remain.
Full execution identity, default-path normalization, cache and error fallback
still need separate evidence; this is not live-provider acceptance.

`python3 scripts/test-usage-reader.py ReaderTests.test_claude_keychain_selectors_choose_provider_account`
failed in all eight cases before repair, then passed. All 31 reader tests pass.
The stub deliberately returns the first matching synthetic record; no assertion
about the real Keychain's ordering is made.
