# roar

[![CI](../../actions/workflows/ci.yml/badge.svg?branch=main)](../../actions/workflows/ci.yml)
[![Nightly](../../actions/workflows/nightly.yml/badge.svg)](../../actions/workflows/nightly.yml)
[![Docs](https://readthedocs.org/projects/roarcli/badge/?version=latest)](https://roarcli.readthedocs.io/)

A CLI for posting macOS notifications from the shell, with optional
click handlers (open a URL, run a shell command, activate an app),
scheduled delivery, custom action buttons, and a `--wait` mode that
blocks until the user clicks, picks a button, or dismisses the
notification.

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
exhaustive help text. Once the man page is installed (see
[Build from source](#build-from-source)), `man roar` is the full
reference.

### Deeper docs

The narrative documentation is rendered at
**[roarcli.readthedocs.io](https://roarcli.readthedocs.io/)** —
searchable, with light/dark theme toggle and per-page edit links
back here. The source lives in `docs/`:

- [`docs/CONCEPTS.md`](docs/CONCEPTS.md) — how macOS notifications
  work end-to-end, why Roar is a bundle-with-a-CLI, identifiers /
  threads / categories, the `--wait` lifecycle.
- [`docs/reference/`](docs/reference/index.md) — exhaustive
  flag-by-flag reference. One page per subcommand
  ([`send`](docs/reference/send.md), [`list`](docs/reference/list.md),
  [`dismiss`](docs/reference/dismiss.md), [`clear`](docs/reference/clear.md),
  [`settings`](docs/reference/settings.md)), plus the overview
  page covering global flags, exit codes, versioning, and the
  installed layout.
- [`docs/COOKBOOK.md`](docs/COOKBOOK.md) — recipes: build-status
  banners, replyable prompts, scheduled reminders, in-place updates,
  attachment thumbnails.
- [`docs/SCRIPTING.md`](docs/SCRIPTING.md) — the `--wait` stdout
  protocol, exit-code dispatch, and patterns for shell, Python, and
  CI integration.
- [`docs/FAQ.md`](docs/FAQ.md) — recurring questions about design
  and scope: install, upgrade, permissions, cross-platform.
- [`docs/SECURITY.md`](docs/SECURITY.md) — full threat model: URL
  scheme allow-list, `--exec` consent gate, attachment hardening,
  same-bundle-id spoofing limits, userInfo bounds.
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — symptom →
  fix for silent notifications, missing badges, Focus filters,
  sound-name lookups, provisional auth, debug logging.
- [`docs/BUILD.md`](docs/BUILD.md) — build from source: requirements,
  the `xcodegen` + `xcodebuild` flow, testing, lint, installing a
  local build over the released one, and regenerating the app icon.
- [`docs/RELEASE.md`](docs/RELEASE.md) — the release pipeline:
  CI workflows, signing / notarisation secrets, tag-and-push,
  and bootstrapping the Homebrew tap.

---

## Examples

Plain notification (`--body` is required; pipe stdin to skip it):

```sh
roar send --title "Build complete" --body "succeeded in 4m23s"
```

Body piped from another command (omit `--body` entirely):

```sh
gh pr list --json title,number | roar send --title "Open PRs"
```

Click to open a URL (default allow-list: http, https, mailto):

```sh
roar send --title "Deploy queued" --body "Click to view CI" \
    --open-url https://ci.example.com/build/42
```

Click to open a custom-scheme URL (must be opted in):

```sh
roar send --title "Open in editor" --body "main.swift" \
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
roar send --title "Switch to Safari" --body "Tap to focus" \
    --activate-bundle-id com.apple.Safari
```

Scheduled delivery — fire after a delay or at a specific time:

```sh
roar send --title "Standup" --body "Meeting in 5 min" --in 5m
roar send --title "End of day" --body "Wrap up" --at '2026-05-15 17:00'
```

Recurring delivery:

```sh
roar send --title "Hourly check" --body "Status ping" --repeat hourly
roar send --title "Standup" --body "Meeting time" --repeat 'weekly:mon:09:00'
```

`--wait` for a click and print the user's choice:

```sh
choice=$(roar send --title "Deploy?" --body "Push v3.2.0 to prod?" \
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

`--open-url` is **allow-list only**. By default `http`, `https`,
and `mailto` are accepted. To open any other scheme add it
explicitly with `--allow-url-scheme <scheme>` (repeat for
multiple). There is **no "accept everything" override** by
design — schemes like `javascript:`, `file:`, `applescript:`,
`afp:` carry click-time RCE / script-exec / auto-mount side
effects that aren't obvious from the URL text.

The send-time allow-list is serialised into the notification's
userInfo and replayed at click time, so the click handler can
never broaden what the send agreed to. For the full catalogue
of dangerous schemes and why each one matters, see
[docs/SECURITY.md → URL scheme allow-list](docs/SECURITY.md#1-url-scheme-allow-list-open-url).

---

## Click-handler threat model (read this if you use `--exec`)

`roar`'s click handler trusts the notification's userInfo to tell
it what to do on click. macOS does not scope notification delivery
by process identity — any same-user process posting under
`io.myers.roar` can craft a notification whose userInfo asks the
click handler to exec a command. The `--allow-shell-on-click`
opt-in is enforced at **send time** by `roar send`, not at click
time by the system.

This is inherent to the ad-hoc-signed local-CLI threat model and
not unique to Roar. The full discussion — what the defences DO
close (NUL-byte rejection, URL scheme allow-list, attachment
hardening, environment scrubbing on `posix_spawn`) and what they
deliberately don't — is in
[docs/SECURITY.md](docs/SECURITY.md#3-same-bundle-id-spoofing-whats-in-scope-what-isnt).

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
roar send --title "Hello" --body "from roar"
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

CI runs SwiftLint + tests on every push and PR, a nightly test
run catches Apple-side regressions, and tagged releases
auto-build a notarised `.app` and (optionally) auto-PR a cask
bump to the Homebrew tap.

Full details — workflow descriptions, the secrets the release
job needs, how to tag a release, and how to bootstrap the
Homebrew tap repo — live in [`docs/RELEASE.md`](docs/RELEASE.md).

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
