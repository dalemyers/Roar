# Release

How the `Roar` release pipeline works, what secrets it needs,
how to cut a new tag, and how to bootstrap the Homebrew tap.
This page is contributor-tier — most users never need it.

## CI workflows

Three GitHub Actions workflows live under `.github/workflows`:

- **`ci.yml`** — runs SwiftLint + `xcodebuild test` on every
  push to `main` and every pull request. `.swiftlint.yml` is
  tuned so the baseline passes; warnings annotate PRs without
  blocking, errors fail the workflow.
- **`nightly.yml`** — re-runs the test suite at 07:00 UTC daily
  so Apple-side regressions (a new Xcode bumped onto
  `macos-latest`, an SDK or toolchain change) surface
  independently of PR activity. Opens / refreshes a tracking
  issue on failure.
- **`release.yml`** — triggered on any `v*` tag push. Builds
  with Developer ID signing, notarises via `xcrun notarytool`,
  staples the receipt onto the `.app`, attaches a `.tar.gz`,
  `.app.zip`, and a sha256 manifest to a new GitHub Release,
  and (if `HOMEBREW_TAP_TOKEN` is set) opens a PR against
  `dalemyers/homebrew-tap` bumping the cask. Manual
  `workflow_dispatch` is available for re-running against an
  existing tag.

## Secrets the release workflow expects

Provision these once under **Settings → Secrets and variables →
Actions**. Until they exist, tagged releases will fail in the
keychain-import step — there is no fallback to ad-hoc signing,
because shipping an unsigned `.app` would be worse than
failing.

| Secret | Purpose |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application certificate exported from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` and pasted. |
| `P12_PASSWORD` | The password used when exporting the `.p12`. |
| `KEYCHAIN_PASSWORD` | Any random string; used as the unlock password for the temp keychain on the runner. Generate with `openssl rand -hex 32`. |
| `APPLE_ID` | Apple ID email associated with the Developer Program account. |
| `APPLE_ID_PASSWORD` | App-specific password generated at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords. NOT the iCloud password. |
| `APPLE_TEAM_ID` | Developer Team ID, the 10-character alphanumeric at https://developer.apple.com/account → Membership. |
| `HOMEBREW_TAP_TOKEN` | *(Optional.)* PAT with `repo` write access to `dalemyers/homebrew-tap`. When set, each tagged release auto-PRs a cask bump to the tap. When absent, the release still succeeds (the tap step skips with a notice). The default `GITHUB_TOKEN` cannot push to another repo, hence the dedicated PAT. |

## Tagging a release

```sh
# Bump CFBundleShortVersionString in project.yml first if needed.
git tag v1.0.0
git push origin v1.0.0
# Watch the Release workflow finish; the tagged release will be
# attached automatically.
```

The git tag is the version source of truth. The workflow does
not auto-bump `project.yml`'s `CFBundleShortVersionString` —
bump it in a commit before tagging if you want the bundle's
reported version to match the release name.

## Bootstrapping the Homebrew tap (one-time)

The auto-PR-cask step expects a `dalemyers/homebrew-tap` GitHub
repo to already exist. To set it up:

1. Create the repo (public, empty README is fine):
   https://github.com/new → name `homebrew-tap`.
2. Copy this repo's `homebrew-tap/Casks/roar.rb` and
   `homebrew-tap/README.md` into the new repo, commit, push to
   `main`. The cask formula in `homebrew-tap/Casks/roar.rb`
   ships with placeholder `version "0.0.0"` and zeroed sha256
   — the first tagged release will overwrite both via the
   workflow's PR.
3. Generate a fine-grained PAT with `Contents: read-write` and
   `Pull requests: read-write` on the tap repo only (NOT on
   `Roar`). Paste it as `HOMEBREW_TAP_TOKEN` in **Settings →
   Secrets and variables → Actions** of this repo.
4. Tag and push a release. The workflow will open a PR against
   the tap; merge it, and
   `brew install --cask dalemyers/tap/roar` resolves to the new
   version.

After step 3 the tap maintenance is automatic. Manual edits to
the cask formula's URL pattern, install stanzas, or zap targets
should go in this repo's `homebrew-tap/Casks/roar.rb` (the
source of truth) so they propagate on the next release rather
than drifting in the tap repo.
