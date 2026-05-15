# Reference

Exhaustive flag-by-flag reference for every `roar` subcommand.
Use Ctrl-F. For recipes that combine flags in context, see the
[Cookbook](../COOKBOOK.md); for the `--wait` stdout protocol used
by scripts, see [Scripting](../SCRIPTING.md); for *why* a given
default was chosen, see [Security](../SECURITY.md).

## Subcommands

| Subcommand | Purpose |
|---|---|
| [`roar send`](send.md) | Post a notification. |
| [`roar list`](list.md) | List delivered + pending notifications. |
| [`roar dismiss`](dismiss.md) | Remove notifications by identifier. |
| [`roar clear`](clear.md) | Bulk-remove notifications by scope. |
| [`roar settings`](settings.md) | Print current OS notification settings. |

Run any subcommand with `--help` for its inline help text. Run
`roar --version` for the bundle version + build number, e.g.
`0.1.9 (10)` — see [Versioning](#versioning) below for the format.

## Conventions used in examples

- Examples include a `--body` argument. Roar treats `--body` as
  required: a bare `roar send --title "..."` from an interactive
  shell exits with `Provide --body, or pipe a body via stdin.`
  (Piping stdin counts; omit `--body` entirely in that case.)
- Code fences use ` ```sh ` for shell snippets and plain text
  for sample output.
- Placeholders are written `<like-this>`; literal flag values
  appear without angle brackets.

---

## Global flags

These work at the top level (`roar --version`) and on every
subcommand (`roar send --help`).

### `--version`

Print the version string and exit. Format:
`<marketing-version> (<build-number>)`, e.g. `0.1.9 (10)` for
release builds, `0.0.0 (yyyyMMddHHmm)` for local dev builds.
See [Versioning](#versioning) below for the field meanings.

### `-h` / `--help`

Print the help text and exit.

---

## Environment variables

### `ROAR_DEBUG`

When set to any non-empty value, `roar`'s click handler prints
diagnostic detail to stderr — workspace open decisions, URL
scheme allow-list verdicts, exec-command refusal reasons. Stderr
in the click-handler process lands in the unified log (because
the click is a launchd-style relaunch), so leave this off in
production. See
[Troubleshooting → debugging the click handler](../TROUBLESHOOTING.md#debugging-the-click-handler).

```sh
ROAR_DEBUG=1 roar send --title "test" --body "test" --exec 'echo hi' --allow-shell-on-click
# ... then click the banner. Verbose stderr now in the unified log.
```

---

## stderr

stderr is **human-oriented and not contractual** — its format
may change between releases without a major-version bump. Scripts
should branch on exit code and parse stdout (see
[Scripting](../SCRIPTING.md)), never stderr.

Categories of message that land on stderr today, for context:

- ArgumentParser usage / validation errors (exit 64).
- `ValidationError` diagnostics from Roar's own validators
  (length caps, control-character rejections, scheme rejections,
  schedule-bound rejections, etc.).
- The one-time provisional-auth warning emitted when `--sound`,
  `--interruption-level time-sensitive`, or `--badge-count` is
  set under provisional authorization (the affordance is being
  silently downgraded).
- `roar dismiss` per-id "unknown identifier" reports.
- Click-handler diagnostics when `ROAR_DEBUG` is set in the
  launchd-visible environment (see
  [Troubleshooting → debugging the click handler](../TROUBLESHOOTING.md#debugging-the-click-handler)).

If you want a clean log on success, redirect (`2>/dev/null`) at
the call site.

---

## Exit codes

| Code | Where | Meaning |
|---|---|---|
| 0 | any | success |
| 1 | any | runtime error (auth denied, URL open failed, exec failed) |
| 2 | `send --wait` | `--wait-timeout` elapsed (`waitTimeoutExitCode`) |
| 3 | `send --wait` | user dismissed the notification (`waitDismissExitCode`) |
| 4 | `dismiss` | no supplied id matched anything (`noMatchExitCode`) |
| 64 | any | `EX_USAGE` — ArgumentParser rejected the invocation |

The full stable scripting protocol (exit codes + `--wait`
stdout) is documented in [Scripting](../SCRIPTING.md).

---

## Versioning

`roar --version` prints `<marketing-version> (<build-number>)`.

- **Marketing version** is the project's semantic version, set
  from the git tag at release time (`v0.1.9` → `0.1.9`). Local
  dev builds use `0.0.0` so unreleased binaries are visibly
  distinct.
- **Build number** is the CI workflow run number for releases,
  monotonically increasing across the project's history. Local
  dev builds substitute a `yyyyMMddHHmm` UTC timestamp derived
  from the executable's mtime — useful when bisecting which
  local rebuild is in play.

The version flows from a single source: the git tag → the
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` xcodebuild
settings → the Info.plist's `CFBundleShortVersionString` /
`CFBundleVersion` → Swift's `Bundle` lookup at runtime. The
GitHub Release name, the Homebrew cask `version` field, the
Info.plist, and `roar --version` all carry the same value.

---

## Installed layout

After `brew install --cask dalemyers/tap/roar`:

| Path | What |
|---|---|
| `/Applications/Roar.app` | The .app bundle |
| `/opt/homebrew/bin/roar` | Symlink to the inner binary (Apple Silicon; `/usr/local/bin/roar` on Intel) |
| `/opt/homebrew/share/man/man1/roar.1` | Symlink to the man page |

Inside the bundle:

| Path | What |
|---|---|
| `Contents/MacOS/roar` | The actual binary |
| `Contents/Info.plist` | Bundle metadata (version, bundle id, `LSUIElement`) |
| `Contents/Resources/Roar.icns` | App icon |
| `Contents/Resources/man/man1/roar.1` | Man page (source for the Homebrew manpath symlink) |
| `Contents/_CodeSignature/` | Notarisation receipt + signature |

User state — not managed by Roar directly, but written by macOS
on Roar's behalf:

| Path | What |
|---|---|
| `~/Library/Preferences/io.myers.roar.plist` | Cached preferences |
| `~/Library/Saved Application State/io.myers.roar.savedState/` | AppKit saved-state directory |

`brew uninstall --cask --zap dalemyers/tap/roar` removes the
.app + symlinks **and** the user-state paths above. Without
`--zap`, the state files remain and the next install inherits
them — usually fine, but `--zap` is the right knob for "clean
slate" reinstalls.

### Where are Roar's notifications stored?

Inside `usernoted`'s per-user database, not in Roar itself.
There's no on-disk file under `~/Library/...` that mirrors "the
notification you can see in Notification Center" — that state
is internal to the daemon. `roar list`,
`roar dismiss`, and `roar clear` go through
`UNUserNotificationCenter`, which proxies to `usernoted`.

To wipe Notification Center across all sources (not just Roar's):

```sh
killall NotificationCenter
killall usernoted   # launchd respawns both immediately
```
