# 07: Copy and i18n

## Rules
1. Every visible string is `String(localized: "…", comment: "…")` or a
   `LocalizedStringKey`. The comment says where it appears.
2. **No concatenating sentence fragments.** Use one localized format string with
   placeholders: `String(localized: "\(provider) has room")`, never
   `provider + " has room"`.
3. Dates go through the existing `clockTime(_:)`: today "3:20 PM", within 6 days
   "Fri 3:20 PM", beyond that "Oct 21". It's already locale-aware via `.formatted`.
4. Durations and countdowns: `Duration.formatted(.units(allowed: [.days, .hours],
   width: .narrow))` → "3d 10h". Don't hand-build "d"/"h".
5. Percentages: `(left / 100).formatted(.percent.precision(.fractionLength(0)))`.
   Never append "%" by hand.
6. Plurals ("1 profile" / "3 profiles", "N out") go through the string catalog
   with plural variations.
7. Provider and profile names, ids, paths and commands are **verbatim**
   (`Text(verbatim:)`).
8. Say what's **left**, not what's used, in every glance surface. "Used" appears
   only in chips and Diagnostics.
9. Don't say "unknown". If something is unknown, don't show it.

## Strings

| Key (suggested) | English |
|---|---|
| fleet.title | Fleet |
| fleet.summary | {machines} machines · {profiles} profiles |
| fleet.nextBest | Open next best |
| machine.self | This Machine |
| machine.online / .offline / .synced | online / offline / synced {relative} |
| profile.active | Active |
| profile.note.signedOut | {n} signed out |
| profile.note.out | {n} out |
| profile.note.outUnchecked | {n} out · {m} unchecked |
| profile.note.low | {n} running low |
| profile.note.ready | All ready |
| row.left | {percent} left |
| row.back | Back |
| row.unmetered | Not metered |
| row.checkFailed | Check failed |
| row.checking | Checking… |
| row.signedOut | Signed out |
| hero.leftWeek / leftMonth | {percent} left this week / this month |
| hero.full | Full allowance left |
| hero.outUntil | Out until {weekday} |
| hero.back | Back {date} at {time} |
| hero.resets | Resets {time} |
| hero.resetsMonthly | Monthly · resets {date} |
| hero.unmetered.head / sub | Usage isn't metered / {provider} doesn't report quota. Start freely. |
| hero.failed.head / sub | Couldn't read usage / The last check failed. You can still start a session. |
| hero.signedOut.head / sub | Not signed in / Sign in to start sessions and read usage. |
| hero.countdown | in {duration} |
| action.checkAgain | Check again |
| suggest.title | {provider} has room |
| suggest.titleOther | {provider} in {profile} has room |
| suggest.sub | {percent} left · resets {day} |
| action.switch | Switch |
| action.start | Start session |
| action.startAnyway | Start anyway |
| action.startIn | in {terminal} |
| action.signIn | Sign in… |
| menu.openIn | Open in |
| tile.openApp / switchAccount / moveSession | Open app / Switch account / Move session |
| detail.configure / diagnostics | Configure / Diagnostics |
| detail.checkedAt | checked {time} |
| diag.copyReport / checkNow | Copy report / Check now |
| config.account / usageAccount / ownedBy | ACCOUNT / Usage account / Owned by {profile} |
| config.launch / terminal / command | LAUNCH / Terminal / Command |
| config.files / config / appData | FILES / Config / App data |
| config.reveal / copy / copied | Reveal in Finder / Copy / Copied |
| config.signInAgain / signOut | Sign in again… / Sign out of {provider} |
| toast.half | {provider} · half left |
| toast.quarter | {provider} · 25% left |
| toast.low | {provider} · 10% left |
| toast.out | {provider} is out |
| toast.pace.lasts | At this pace it lasts until the reset, {time}. |
| toast.pace.ahead | You're ahead of pace. At this rate it runs out {time}. |
| toast.pace.hours | About {duration} of work left at this pace. |
| toast.pace.usedLabel / elapsedLabel | {percent} used / {percent} of the week gone |
| toast.notifyBack | Notify when back |
| toast.now | now |
| a11y.toast | {title}. {subline} |
