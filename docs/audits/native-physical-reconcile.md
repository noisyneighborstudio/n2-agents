# Native physical-peer recovery

The isolated packaged app displayed the real dispatcher's unreachable M5 task.
Clicking **Check in** started its production action. A FIFO held the CLI reply;
Settings opened while task metadata was still unreachable. After release, the
real signed SSH reconciliation recovered completed state and the native row
showed **finished**. The physical controller verified exactly one execution.

```sh
N2_QA=1 N2_SIGN_IDENTITY=- zsh tray/build.sh
scripts/accept-native-physical-reconcile.sh --peer sethwebster@100.88.174.82 --artifacts /private/tmp/n2-native-physical-proof
```

The command requires existing SSH trust and macOS accessibility/screen capture
access. It copies the QA package, gives it a unique bundle identifier and home,
removes fleet-QA selection and URL handlers, and ad-hoc signs it. Its CLI adapter
allows real disposable fleet reads and reconciliation only; profile/session
feeds are empty, so no live accounts or provider tasks participate. The source
SSH fixture owns synthetic peers and commands. No production app is installed.

The initial automated capture raced native publication after CLI completion.
The final command waits for the actual label through Apple's
[accessibility layout notifications](https://developer.apple.com/documentation/applicationservices/kaxlayoutchangednotification)
and value/window events, with a timeout only to fail a stuck observer. It waits
for the initial unreachable label too. SwiftUI exposes these fixture buttons
without names, so the runner asserts the observed ten-button layout before
pressing Check in. Layout changes fail acceptance rather than choosing by guess.

Negative proof: the real unreachable AX capture fails the finished predicate.
`N2_NATIVE_FAIL_BEFORE_READ=1` injects failure before the initial read; the run
failed, its copied app exited, and its bundle was removed. Cleanup validates the
unique executable path independently of a CLI PID receipt. It releases only the
fixture FIFO, terminates only that app, and retains screenshots/AX/CLI receipts.

All three final screenshots were visually inspected. The sibling QA artifact
folder `native-physical-reconcile` retains them; the JSON records their hashes
and physical task receipt. Independent correctness review is clear. Desktop
banner delivery, live-provider attribution and other fleet flows remain separate
acceptance requirements. Physical/UI acceptance is opt-in, not claimed by CI.
