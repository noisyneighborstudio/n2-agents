# Credential-store observation spike

Apple's [SecItemCopyMatching](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))
returns a signed OSStatus separately from returned item data. This permits a
caller to retain error information instead of reducing it to the security CLI's
exit status. Apple recommends an authentication context with interaction disabled
in place of the deprecated [authentication UI flag](https://developer.apple.com/documentation/security/ksecuseauthenticationuifail).
The [context key](https://developer.apple.com/documentation/security/ksecuseauthenticationcontext)
and [interaction property](https://developer.apple.com/documentation/localauthentication/lacontext/interactionnotallowed)
are available on macOS; the installed SDK accepted the candidate query.

## Recorded proof

A disposable Swift probe used real Security constants and LAContext but injected
the copy function. It never invoked SecItemCopyMatching. Eight cases checked
reported absence, interaction refusal, authentication failure, unavailable store,
wrong returned type, invalid UTF-8, empty data and a present synthetic token.
The closure also asserted service/account selection and disabled interaction.
Only the item-not-found status mapped to no-token; other failures or malformed
successes mapped to credential-store-unavailable. No token bytes were printed.
The adjacent JSON retains the status fixtures, source hash and limits.

Independent review checked all observations and the source hash. Exploratory
Swift and its executable were discarded. No real Keychain was read or written,
no provider was contacted and no production collector was changed.

## Legacy source finding and decision

The pinned [Apple legacy implementation](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_keychain/lib/SecItem.cpp)
changes the proposed replacement plan. Its search loop does not retain the
iteration failure status. With no matches or separate recorded error, it returns
item-not-found. A compiled extraction of that unchanged loop, using synthetic
callees, mapped interaction/authentication/store search failures to item-not-found.
Successful data retrieval stayed successful; a data-return error was preserved.
Six observations and the source/extraction hashes are retained in the JSON.
Independent source review confirmed the finding. This does not establish the
behavior of every installed macOS build.

The first eight fixtures therefore establish classification only after an API
has reported a status. They cannot prove that its internal search retained the
original failure. Merely replacing security with SecItemCopyMatching is not a
verified repair. Exploratory code from both probes was discarded after review.

The next code slice will classify ambiguous security exit 44 as unavailable,
without claiming a missing login. Successful reads remain unchanged. No native
helper is justified by this evidence. Broader Keychain lifecycle and provider
identity acceptance remain required; legacy search scope, ACL behavior and prompt
suppression have not been verified by these synthetic fixtures.
