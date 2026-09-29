# 10: Open questions (don't guess; ask the design owner)

| # | Question | Blocks | Default until answered |
|---|---|---|---|
| Q1 | Which CLI verb returns profiles and usage **held on peer machines**? `PanelData` has local profiles only, and `FleetPeer` has no profile list. | S9 | Show only the "This Machine" section |
| Q2 | How should these notes read: `credentialOverride`, `credentialStoreUnavailable`, `ownerUnavailable`, `migrationPending`? | S1 copy | `.checkFailed`, with the raw note in Diagnostics |
| Q3 | Do the ready colors break at 50 (green) and 20 (yellow)? Existing `meterColor` breaks on *used* at 50 and 80, with red at 80+. The redesign reserves red for signed out. | S1 | Use the redesign's breaks |
| Q4 | Restore the last navigation path when the panel reopens? For how long? | S3 | 60 s |
| Q5 | Should the panel keep a "Recent warnings" list, so dismissed toasts stay reachable (keyboard and VoiceOver)? | S8 | No list. Toasts post announcements only |
| Q6 | Does the CLI report credits for Codex (the "0 credits" chip)? | S4 | Hide the chip if absent |
| Q7 | "Notify when back" on the out toast: does it mean a local notification at reset time? Does that require `UNUserNotificationCenter` permission? | S8 | Ship without the button |
| Q8 | Should "Move session" (Transfer session) be available on remote-machine profiles? | S9 | Local only |
