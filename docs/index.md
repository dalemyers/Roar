# Roar

A CLI for posting macOS notifications from the shell, with optional
click handlers (open a URL, run a shell command, activate an app),
scheduled delivery, custom action buttons, and a `--wait` mode that
blocks until the user interacts.

```sh
roar send --title "Build complete" --body "$(git log -1 --pretty=%B)"
```

Roar is an ad-hoc-signed AppKit bundle with no UI surface — it
sets `LSUIElement: true`, so notifications post quietly and the
binary behaves like a normal terminal CLI: it exits as soon as
`usernoted` has accepted the request, or when the user
interacts (in `--wait` mode).

## Install

```sh
brew install --cask dalemyers/tap/roar
```

That installs `Roar.app` to `/Applications`, symlinks the `roar`
binary onto your Homebrew bin path, and installs the man page so
`man roar` works without further setup. Requires macOS 13
(Ventura) or later.

For manual installs without Homebrew, see the README's
[Install](https://github.com/dalemyers/Roar#install) section.

## Subcommands

- `roar send`     post a notification
- `roar list`     list delivered and pending notifications
- `roar dismiss`  remove a notification by identifier
- `roar clear`    remove notifications by scope (delivered / pending / all)
- `roar settings` print current notification settings (Focus, badges, etc.)

`roar --help` and `roar <subcommand> --help` show every flag with
exhaustive help text. The man page (`man roar` after install) is
the full reference.

## Where to read next

- **[Cookbook](COOKBOOK.md)** — recipes: build-status banners,
  replyable prompts, scheduled reminders, in-place updates,
  attachment thumbnails.
- **[Scripting](SCRIPTING.md)** — the `--wait` stdout protocol,
  exit-code dispatch, patterns for shell / Python / CI
  integration.
- **[Security](SECURITY.md)** — full threat model: URL scheme
  allow-list, `--exec` consent gate, attachment hardening,
  same-bundle-id spoofing limits, userInfo bounds.
- **[Troubleshooting](TROUBLESHOOTING.md)** — silent
  notifications, missing badges, Focus filters, sound-name
  lookups, provisional auth, debug logging.
- **[Build from source](BUILD.md)** — `xcodegen` + `xcodebuild`
  flow, running the test suite, lint, replacing an installed
  build with a local one, regenerating the app icon.

## Quick reference

### Exit codes

| Code | Meaning |
|------|---------|
| 0    | success (default click in `--wait`, or non-wait success) |
| 1    | runtime error (auth denied, URL open failed, command failed) |
| 2    | `--wait` timeout elapsed (`timeout` printed on stdout) |
| 3    | `--wait` user dismissed the notification (`dismiss` printed) |
| 4    | `roar dismiss <id>` and no id matched any delivered or pending |
| 64   | `EX_USAGE` — ArgumentParser rejected the invocation |

### Click-handler threat model (important if you use `--exec`)

Roar's click handler trusts the notification's userInfo to tell
it what to do on click. macOS does not scope notification
delivery by process identity — any process running as your user
that posts under the bundle id `io.myers.roar` can craft a
notification whose userInfo asks the click handler to exec a
command. The `--allow-shell-on-click` opt-in is enforced at
**send time** by `roar send`, not at click time by the system.

This is inherent to the ad-hoc-signed local-CLI threat model and
the same constraint that applies to every other CLI-as-bundle
tool in this category. The full threat-model discussion is in
[Security](SECURITY.md).
