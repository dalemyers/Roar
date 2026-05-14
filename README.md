# roar

[![CI](../../actions/workflows/ci.yml/badge.svg?branch=main)](../../actions/workflows/ci.yml)
[![Nightly](../../actions/workflows/nightly.yml/badge.svg)](../../actions/workflows/nightly.yml)
[![Docs](https://readthedocs.org/projects/roarcli/badge/?version=latest)](https://roarcli.readthedocs.io/)

A CLI for posting macOS notifications from the shell, with optional
click handlers (open a URL, run a shell command, activate an app),
scheduled delivery, custom action buttons, and a `--wait` mode that
blocks until the user interacts.

```sh
roar send --title "Build complete" --body "$(git log -1 --pretty=%B)"
```

`roar` is an ad-hoc-signed AppKit bundle with no UI surface (it sets
`LSUIElement: true`), so notifications post quietly and the binary
behaves like a normal terminal CLI: it exits as soon as `usernoted`
has accepted the request, or when the user interacts (in `--wait`
mode).

---

## Subcommands

- `roar send`     post a notification
- `roar list`     list delivered and pending notifications
- `roar dismiss`  remove a notification by identifier
- `roar clear`    remove notifications by scope (delivered / pending / all)
- `roar settings` print current notification settings (Focus, badges, etc.)

`roar --help` and `roar <subcommand> --help` show every flag with
exhaustive help text. Once the man page is installed (see [Build](#build)),
`man roar` is the full reference.

### Deeper docs

The narrative documentation is rendered at
**[roarcli.readthedocs.io](https://roarcli.readthedocs.io/)** —
searchable, with light/dark theme toggle and per-page edit links
back here. The source lives in `docs/`:

- [`docs/BUILD.md`](docs/BUILD.md) — build from source: requirements,
  the `xcodegen` + `xcodebuild` flow, testing, lint, installing a
  local build over the released one, and regenerating the app icon.
- [`docs/COOKBOOK.md`](docs/COOKBOOK.md) — recipes: build-status
  banners, replyable prompts, scheduled reminders, in-place updates,
  attachment thumbnails.
- [`docs/SCRIPTING.md`](docs/SCRIPTING.md) — the `--wait` stdout
  protocol, exit-code dispatch, and patterns for shell, Python, and
  CI integration.
- [`docs/SECURITY.md`](docs/SECURITY.md) — full threat model: URL
  scheme allow-list, `--exec` consent gate, attachment hardening,
  same-bundle-id spoofing limits, userInfo bounds.
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — silent
  notifications, missing badges, Focus filters, sound-name lookups,
  provisional auth, debug logging.

---

## Examples

Plain notification:

```sh
roar send --title "Build complete"
```

Body piped from another command:

```sh
gh pr list --json title,number | roar send --title "Open PRs" --body -
```

Click to open a URL (default allow-list: http, https, mailto):

```sh
roar send --title "Deploy queued" --open-url https://ci.example.com/build/42
```

Click to open a custom-scheme URL (must be opted in):

```sh
roar send --title "Open in editor" \
    --open-url 'vscode://file//Users/me/code/main.swift' \
    --allow-url-scheme vscode
```

Click to run a shell command (opt-in required):

```sh
roar send --title "Build complete" --body "Click to rebuild" \
    --exec 'cd ~/code && make' --allow-shell-on-click
```

Click to activate an app:

```sh
roar send --title "Switch to Safari" --activate-bundle-id com.apple.Safari
```

Scheduled delivery — fire after a delay or at a specific time:

```sh
roar send --title "Standup" --in 5m
roar send --title "End of day" --at '2026-05-15 17:00'
```

Recurring delivery:

```sh
roar send --title "Hourly check" --repeat hourly
roar send --title "Standup" --repeat 'weekly:mon:09:00'
```

`--wait` for a click and print the user's choice:

```sh
choice=$(roar send --title "Deploy?" \
    --action approve:Approve --action reject:Reject::destructive \
    --wait --wait-timeout 30s)
case "$choice" in
    approve) ./deploy.sh ;;
    reject)  echo "user rejected" ;;
    timeout) echo "no response" ;;
esac
```

---

## URL scheme allow-list

`--open-url` is **allow-list only**. By default `http`, `https`, and
`mailto` are accepted. To open any other scheme you must add it
explicitly with `--allow-url-scheme <scheme>` (repeat for multiple).

There is **no "accept everything" override** by design. Some schemes
have click-time side effects that aren't obvious:

- `javascript:` and `data:` run script in the default browser.
- `file:`, `afp:`, `smb:`, `nfs:`, `ftp:` hand attacker-controllable
  paths or remote mounts to LaunchServices / Finder, which then
  auto-opens content from the mounted location.
- `applescript:`, `help:`, `x-apple-helpbasic:`, `shell:` have a
  history of arbitrary-code-execution CVEs.
- `webcal:`, `feed:`, `news:`, `nntp:` auto-subscribe Calendar /
  RSS / Usenet readers to attacker-supplied feeds.
- `telnet:`, `rlogin:`, `tn3270:` launch Terminal with an
  attacker-chosen target host (and, for the first two, plaintext
  credentials over the wire).
- `tel:`, `sms:`, `facetime:`, `imessage:` initiate calls / draft
  messages on click.

If your workflow needs one of those, enable it explicitly —
`--allow-url-scheme tel` to dial from a notification, etc. The
send-time allow-list is serialised into the notification's userInfo
and replayed at click time so the click handler never broadens what
the send agreed to.

---

## Click-handler threat model (read this if you use `--exec`)

`roar`'s click handler trusts the notification's userInfo to tell it
what to do on click. macOS does not scope notification delivery by
process identity — *any process running as your user that posts
under the same bundle identifier* can post a notification and the
click handler will obey its userInfo.

Concretely: a same-user process posting as `io.myers.roar` can craft a
notification with `roar.exec.consent=1` + an arbitrary
`roar.exec.command`, and when you click the banner the handler will
run that command. The `--allow-shell-on-click` opt-in is enforced at
**send time** by `roar send`, not at click time by the system; the
click handler has no cryptographic way to distinguish "your `roar send`
posted this" from "some other process posted this".

This is inherent to the ad-hoc-signed local-CLI threat model: a
same-user attacker who can post under your bundle id can already
exec as your user without going through `roar`. The defenses that
DO apply (NUL-byte rejection, the URL scheme allow-list, attachment
path canonicalisation + symlink walk, attachment control-character
re-screening, environment scrubbing on `posix_spawn`) close the
attack shapes that don't require local-process compromise.

If you're not running random untrusted code as your user, the
practical risk is low. If you are, the relevant defense is at the
OS / sandbox layer, not in `roar`.

---

## Install

Requires macOS 13 (Ventura) or later. `roar` runs as a notification
sender from the shell; you'll be asked once for notification
permission the first time you `send`.

### Homebrew (recommended)

```sh
brew install --cask dalemyers/tap/roar
```

That single command:

- Downloads the notarised, stapled `Roar.app` from the latest GitHub
  release.
- Installs it to `/Applications/Roar.app`.
- Symlinks the embedded binary onto your Homebrew bin path
  (`/opt/homebrew/bin/roar` on Apple Silicon, `/usr/local/bin/roar`
  on Intel) so `roar` works from any shell.
- Symlinks the man page into Homebrew's manpath so `man roar` works
  immediately.

Verify:

```sh
roar --version
roar send --title "Hello from roar"
```

Upgrade:

```sh
brew update && brew upgrade --cask dalemyers/tap/roar
```

Uninstall (with state cleanup):

```sh
brew uninstall --cask --zap dalemyers/tap/roar
```

### Manual (no Homebrew)

Download the latest `roar-<version>.app.zip` from the
[Releases](../../releases) page (or fetch via `gh`):

```sh
VERSION=$(gh release view --repo dalemyers/Roar --json tagName -q .tagName)
gh release download "$VERSION" --repo dalemyers/Roar --pattern '*.app.zip'
unzip "roar-${VERSION#v}.app.zip"
mv Roar.app /Applications/
```

Then put `roar` on your PATH and register the man page. Pick the
paths matching your Homebrew prefix (or wherever your `bin`/`man`
search paths point):

```sh
# Apple Silicon (Homebrew prefix /opt/homebrew):
ln -sf /Applications/Roar.app/Contents/MacOS/roar \
       /opt/homebrew/bin/roar
ln -sf /Applications/Roar.app/Contents/Resources/man/man1/roar.1 \
       /opt/homebrew/share/man/man1/roar.1

# Intel (Homebrew prefix /usr/local) — also works on systems without
# Homebrew if you have write access to /usr/local:
ln -sf /Applications/Roar.app/Contents/MacOS/roar \
       /usr/local/bin/roar
sudo ln -sf /Applications/Roar.app/Contents/Resources/man/man1/roar.1 \
            /usr/local/share/man/man1/roar.1
```

If you skip the manpath symlink, `man roar` still works once you
add the embedded path to `MANPATH`:

```sh
export MANPATH="/Applications/Roar.app/Contents/Resources/man:${MANPATH:-}"
```

### Known limitations after install

- **Notification icon shows Terminal, not Roar.** When `roar` is
  exec'd from Terminal, macOS attributes notifications to
  Terminal's `responsible_pid` for icon purposes, regardless of
  `roar`'s own bundle identifier. Click handlers, permissions, and
  every other attribution route to Roar correctly — only the
  banner glyph is affected. Fix is non-trivial (requires a private
  Darwin API in a way that interacts badly with the hardened
  runtime) and tracked as a separate piece of work.

---

## Build from source

```sh
xcodegen && xcodebuild -project Roar.xcodeproj -scheme roar build
```

Tests:

```sh
xcodebuild -project Roar.xcodeproj -scheme roar -destination 'platform=macOS' test
```

Man page:

```sh
./man/install.sh           # per-user, ~/.local/share/man
./man/install.sh --system  # /usr/local/share/man (needs sudo)
```

---

## CI / release

Three GitHub Actions workflows are wired up under `.github/workflows`:

- **`ci.yml`** — runs SwiftLint + `xcodebuild test` on every push to
  `main` and every pull request. `.swiftlint.yml` is tuned so the
  baseline passes; warnings annotate PRs without blocking, errors
  fail the workflow.
- **`nightly.yml`** — re-runs the test suite at 07:00 UTC daily so
  Apple-side regressions (a new Xcode bumped onto `macos-latest`,
  an SDK or toolchain change) surface independently of PR activity.
  Opens / refreshes a tracking issue on failure.
- **`release.yml`** — triggered on any `v*` tag push. Builds with
  Developer ID signing, notarises via `xcrun notarytool`, staples
  the receipt onto the `.app`, attaches a `.tar.gz`, `.app.zip`,
  and a sha256 manifest to a new GitHub Release, and (if
  `HOMEBREW_TAP_TOKEN` is set) opens a PR against
  `dalemyers/homebrew-tap` bumping the cask. Manual
  `workflow_dispatch` is available for re-running against an
  existing tag.

### Secrets the release workflow expects

Provision these once under `Settings → Secrets and variables →
Actions`. Until they exist, tagged releases will fail in the
keychain-import step — there is no fallback to ad-hoc signing,
because shipping an unsigned `.app` would be worse than failing.

| Secret | Purpose |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application certificate exported from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` and pasted. |
| `P12_PASSWORD` | The password used when exporting the `.p12`. |
| `KEYCHAIN_PASSWORD` | Any random string; used as the unlock password for the temp keychain on the runner. Generate with `openssl rand -hex 32`. |
| `APPLE_ID` | Apple ID email associated with the Developer Program account. |
| `APPLE_ID_PASSWORD` | App-specific password generated at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords. NOT the iCloud password. |
| `APPLE_TEAM_ID` | Developer Team ID, the 10-character alphanumeric at https://developer.apple.com/account → Membership. |
| `HOMEBREW_TAP_TOKEN` | *(Optional.)* PAT with `repo` write access to `dalemyers/homebrew-tap`. When set, each tagged release auto-PRs a cask bump to the tap. When absent, the release still succeeds (the tap step skips with a notice). The default `GITHUB_TOKEN` cannot push to another repo, hence the dedicated PAT. |

### Tagging a release

```sh
# Bump CFBundleShortVersionString in project.yml first if needed.
git tag v1.0.0
git push origin v1.0.0
# Watch the Release workflow finish; the tagged release will be
# attached automatically.
```

The git tag is the version source of truth. The workflow does not
auto-bump `project.yml`'s `CFBundleShortVersionString` — bump it in
a commit before tagging if you want the bundle's reported version
to match the release name.

### Bootstrapping the Homebrew tap (one-time)

The auto-PR-cask step expects a `dalemyers/homebrew-tap` GitHub
repo to already exist. To set it up:

1. Create the repo (public, empty README is fine):
   https://github.com/new → name `homebrew-tap`.
2. Copy this repo's `homebrew-tap/Casks/roar.rb` and
   `homebrew-tap/README.md` into the new repo, commit, push to
   `main`. The cask formula in `homebrew-tap/Casks/roar.rb` ships
   with placeholder `version "0.0.0"` and zeroed sha256 — the
   first tagged release will overwrite both via the workflow's PR.
3. Generate a fine-grained PAT with `Contents: read-write` and
   `Pull requests: read-write` on the tap repo only (NOT on
   `Roar`). Paste it as `HOMEBREW_TAP_TOKEN` in
   `Settings → Secrets and variables → Actions` of THIS repo.
4. Tag and push a release. The workflow will open a PR against
   the tap; merge it, and `brew install --cask dalemyers/tap/roar`
   resolves to the new version.

After step 3 the tap maintenance is automatic. Manual edits to
the cask formula's URL pattern, install stanzas, or zap targets
should go in this repo's `homebrew-tap/Casks/roar.rb` (the source
of truth) so they propagate on the next release rather than
drifting in the tap repo.

---

## Exit codes

| Code | Meaning |
|------|---------|
| 0    | success (default click in `--wait`, or non-wait success) |
| 1    | runtime error (auth denied, URL open failed, command failed) |
| 2    | `--wait` timeout elapsed (`timeout` printed on stdout) |
| 3    | `--wait` user dismissed the notification (`dismiss` printed) |
| 4    | `roar dismiss <id>` and no id matched any delivered or pending |
| 64   | EX_USAGE — ArgumentParser rejected the invocation |
