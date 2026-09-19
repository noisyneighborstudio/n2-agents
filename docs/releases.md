# Release and update pipeline

N2 Agents updates itself with Sparkle 2, on two channels:

| Push to  | Channel    | Version (semantic-release) | Feed                               |
| -------- | ---------- | -------------------------- | ---------------------------------- |
| `main`   | Continuous | `1.4.0-continuous.3`       | `$N2_FEED_BASE_URL/continuous/appcast.xml` |
| `stable` | Stable     | `1.4.0`                    | `$N2_FEED_BASE_URL/stable/appcast.xml`     |

`.github/workflows/release.yml` runs `scripts/test.sh`, then semantic-release. semantic-release reads conventional commits (`feat:` minor, `fix:` patch, `!`/`BREAKING CHANGE:` major), tags the repo and creates the GitHub release; a push with no releasable commits publishes nothing. Runs are serialized, so the two channels never race.

- **Version.** `CFBundleShortVersionString` is semantic-release's version. `CFBundleVersion` is the workflow run number (`N2_BUILD_NUMBER`), which only increases, across both channels — Sparkle orders updates by it. Renaming the workflow file resets the run number, so don't.
- **Build.** `scripts/release-prepare.sh` → `scripts/release-build.sh` → `tray/build.sh` builds `N2 Agents.app`, Developer ID signs it, notarizes and staples it, and zips it twice: `N2Agents.zip` (what `install.sh` downloads) and `N2Agents-<channel>-<version>.zip` (the appcast enclosure).
- **Publish.** `scripts/publish-appcast.sh` signs the channel zip with the Sparkle EdDSA key, checks the signature against the `SUPublicEDKey` baked into the app, uploads both zips to the release, then commits `<channel>/appcast.xml` (built by `scripts/make-appcast.sh`) to the `appcasts` branch.

## Hosting

The source repo is private, so builds are published to the public [`noisyneighborstudio/n2-agents-updates`](https://github.com/noisyneighborstudio/n2-agents-updates): release zips as assets, feeds on its `appcasts` branch, and `install.sh` on `main` (refreshed by every stable release). Writing there needs the `N2_UPDATES_TOKEN` secret. N2's Sparkle key is the login-keychain account `n2agents` (`generate_keys --account n2agents`).

`updates.env` is the one place update hosting is configured: `N2_UPDATES_REPO` (the GitHub repo holding the release zips and the `appcasts` branch) and `N2_FEED_BASE_URL` (the public URL serving that branch). `tray/build.sh` bakes the feed URLs into the app; `install.sh` carries a copy of `N2_UPDATES_REPO`, which `scripts/test.sh` keeps equal. Both must be readable without credentials — Sparkle and `install.sh` never authenticate, so a private repo serves only 404s. Changing hosting only reaches installs built after the change, since the feed URL lives in each app's Info.plist.

## One-time setup

1. Create the `stable` branch from `main` (`git push origin main:stable`). semantic-release refuses to run without its release branch.
2. Add the repo secrets:

| Secret | What |
| ------ | ---- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Developer ID Application certificate + private key, exported from Keychain Access as .p12, base64 (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the .p12 export password |
| `BUILD_KEYCHAIN_PASSWORD` | any random string (password of the throwaway CI keychain) |
| `DEVELOPER_ID_APPLICATION` | the identity name, e.g. `Developer ID Application: Name (TEAMID)` (`security find-identity -v -p codesigning`) |
| `SPARKLE_PRIVATE_KEY` | Sparkle's EdDSA private key, exported with `generate_keys -x key-file`; its public half must be `SUPublicEDKey` in `tray/Info.plist` (`generate_keys -p`) |
| `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_KEY_ISSUER` | App Store Connect API key (Users and Access → Integrations → Team Keys, Developer role): the .p8 contents, its key ID, the issuer ID |
| `N2_UPDATES_TOKEN` | only when `N2_UPDATES_REPO` is another repo: a fine-grained token with Contents read/write on it |

Without the notary secrets the run publishes a signed but un-notarized build and logs a warning. Key material stays in runner-temporary files or stdin and is removed in an `always()` step; never pass a private key as an argument or store it in the checkout.

## Promoting to Stable

Fast-forward `stable` to the `main` commit you want (`git push origin <sha>:stable`), or merge `stable` back into `main` afterwards. Otherwise the stable tag isn't in `main`'s history and continuous versions keep counting toward a version already shipped.

## In the app

The app defaults to Stable. **Update Channel** persists Stable or Continuous in `UserDefaults`; the Sparkle delegate returns that channel's feed URL and allows only that `sparkle:channel`. Sparkle rejects malformed feeds, other channels, and archives without a valid signature, without touching the installed app.

## Local builds

`tray/build.sh` stamps `N2_VERSION` (else the latest tag), `N2_BUILD_VERSION` (else 1) and, when set, `N2_SPARKLE_PUBLIC_KEY` over the committed key. `scripts/release-build.sh <version> <build-number>` builds and zips a release locally; set `NOTARY_KEY_FILE`, `NOTARY_KEY_ID` and `NOTARY_KEY_ISSUER` to notarize.
