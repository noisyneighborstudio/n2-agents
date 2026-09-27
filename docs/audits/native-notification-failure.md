# Native notification failures

Permission refusal, authorization errors and rejected notification submissions now
produce a visible fleet-panel warning. Task rows and activity remain available.
Submission callbacks aggregate per batch on the main queue: one successful
callback cannot hide another failure. Only the newest attempt updates the warning.
A successful later submission clears the warning; it does not claim delivery.

## Proof and limits

`python3 scripts/test-native-notification.py` compiles the exact production
announcement method with FleetModel and a synthetic notification center. It checks
first-read suppression, denial, authorization errors, rejected submissions, mixed
batch results, obsolete callbacks, success and repeated-feed deduplication. The
old method failed with `denied permission must be visible`; its local receipt is
`/private/tmp/n2-notification-negative.log`. Full tests and smoke include this proof.

Two inspected 360-point renders of the actual FleetSection show permission and
submission warnings above retained task/activity rows. Source and image hashes
are in the adjacent JSON. These are component renders, not packaged-app delivery.

The earlier disposable, ad-hoc-signed OS probe used a unique bundle and isolated
HOME. Without requesting permission, it recorded authorization status 0 and three
UNErrorDomain code 1 submission refusals. The delivered set was empty at callback
completion. The adjacent JSON retains these fixtures; exploratory code is discarded.
This proves the OS refusal boundary, not authorized delivery or the production path.

Apple documents [foreground notification handling](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate)
and [delivered-notification inspection](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getdeliverednotifications(completionhandler:)).
Authorized foreground/background delivery and visible banners remain required
acceptance work. No notification-center delegate is configured yet. This slice
preserves first-read suppression, the five-notice cap and existing seen-ID behavior;
it does not introduce automatic retry or replay old notices after permission changes.
