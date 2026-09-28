# Codex managed-auth concurrency

Reviewed September 26, 2026 against the current
[official managed-auth automation guide](https://learn.chatgpt.com/docs/auth/ci-cd-auth)
and [credential-storage documentation](https://learn.chatgpt.com/docs/auth).

The automation guide limits its managed ChatGPT `auth.json` workflow to one
machine or a serialized job stream. It explicitly advises against sharing the
same file across concurrent jobs or machines, and names another machine rotating
the token as one cause of refresh failure. External `chatgptAuthTokens` host
integrations are outside that workflow.

N2 currently classifies Codex auth sharing as partial. Its opt-in file sync
replicates `auth.json`, detects divergent file edits, and reports concurrent
provider refresh as unverified. A successful receiving-machine usage request
proves that the copied access token worked then. It does not establish a safe
refresh lifecycle.

Inference: reconciling divergent files after rotation cannot itself prevent
provider-side invalidation of an earlier refresh grant. Fleet account identity
and the ownership of a refreshable login therefore need separate treatment.
The current account-bound runner uses an existing access token in ephemeral
storage and does not implement renewal ownership.

This is a required authentication-lifecycle follow-up before PR #3 is ready.
Evaluate independently authenticated machine grants or a serialized credential
owner serving supported external-token clients. No choice is implemented or
claimed verified by this audit. No live credential was changed, and this finding
does not establish the cause of the original M4 incident.
