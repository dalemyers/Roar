# FAQ

Short answers to recurring questions. For *symptom →
diagnostic* style entries, see
[Troubleshooting](TROUBLESHOOTING.md) instead — FAQs here are
about Roar's design, scope, and trade-offs.

## General

### What is Roar, in one line?

A CLI for posting macOS notifications from the shell, with
click handlers, scheduling, and a `--wait` mode that blocks
until the user reacts.

### Why is `roar` a `.app` bundle and not just a binary?

`UNUserNotificationCenter` — Apple's notification framework —
refuses to operate from a binary that isn't part of an app
bundle. The bundle is also where the click-handler relaunch
lands (macOS re-launches the bundle on click), and where the
notification permission grant is anchored. Roar uses
`LSUIElement: true` so the bundle has no Dock tile and no
window, behaving like a normal terminal CLI. The inner binary
at `Contents/MacOS/roar` is what you exec; the wrapping is
purely for macOS framework compliance.

### Does Roar work on Linux / Windows?

No. Roar is macOS-only and depends on `UserNotifications.framework`,
`UNUserNotificationCenter`, AppKit, and macOS's specific
notarisation / Gatekeeper model. There's no plan to port.
For Linux equivalents look at `notify-send` (libnotify);
for Windows look at `BurntToast` (PowerShell).

### What's the minimum macOS version?

macOS 13 (Ventura). The bundle's `LSMinimumSystemVersion` is
13.0; the build target's `MACOSX_DEPLOYMENT_TARGET` is 13.0.
Older macOSes won't launch the .app at all.

### Why does `roar --version` show two numbers?

Format is `<marketing-version> (<build-number>)`, e.g.
`0.1.9 (10)`. Marketing version comes from the release tag;
build number is the CI workflow run number for tagged
builds, or a `yyyyMMddHHmm` timestamp for local dev builds. The
build number is monotonic across the repo's CI history —
useful for bisecting which exact build a user is on. See
[Reference → Versioning](reference/index.md#versioning).

### Why does the notification show the Terminal icon, not Roar's?

macOS attributes notifications by the kernel's `responsible_pid`
flag, not by `Bundle.main.bundleIdentifier`. A binary `exec`'d
from Terminal inherits Terminal's `responsible_pid`, so
`usernoted` looks up Terminal's icon for the banner. The
notification's *content* — title, body, click handlers,
permission grant — is correctly attributed to Roar; only the
icon glyph is wrong.

There IS a private-API fix (`responsibility_spawnattrs_setdisclaim`
+ `POSIX_SPAWN_SETEXEC` re-exec) but it interacts badly with
the hardened runtime in ways we couldn't debug cleanly — see
the comment block at the top of `Sources/main.swift` and the
git history around v0.1.6 / v0.1.7. A child-spawn variant is
the next thing to try; tracked as a separate piece of work.

## Install & upgrade

### How do I install Roar?

```sh
brew install --cask dalemyers/tap/roar
```

For non-Homebrew installs see the README's
[Install](https://github.com/dalemyers/Roar#install) section.

### How do I upgrade?

```sh
brew update && brew upgrade --cask dalemyers/tap/roar
```

The release pipeline auto-opens a PR against the tap on every
tagged release; the cask formula's `version` and `sha256` get
bumped once that PR is merged. So upgrades are typically
"merge the bump PR, then `brew upgrade`."

### How do I uninstall Roar?

```sh
brew uninstall --cask --zap dalemyers/tap/roar
```

`--zap` removes user state (notification permission record,
saved-state directory) in addition to the .app and symlinks.

### Can I install Roar without Homebrew?

Yes. Download `roar-<version>.app.zip` from the
[Releases](https://github.com/dalemyers/Roar/releases) page,
unzip into `/Applications`, symlink the inner binary onto your
PATH. Step-by-step in the README's
[Manual install](https://github.com/dalemyers/Roar#manual-no-homebrew)
section. The releases are notarised and stapled, so they pass
Gatekeeper without further dance.

## Permissions & first-run

### Do I need to grant any permissions?

Yes — macOS requires per-bundle notification permission.

On first send, Roar requests **provisional** authorization
silently (no dialog, no blocking prompt). Provisional notifications
post quietly to Notification Center: no banner, no sound. To
promote to full auth, either:

- Tap **Keep** on the first notification Roar delivers, **or**
- Open **System Settings → Notifications → Roar** and enable
  the alert style you want.

Once promoted, every subsequent notification posts with full
affordances. The promotion survives reboots.

### Why doesn't my notification have a banner / sound?

Almost always: you're still under provisional auth. See the
question above. `roar settings` will show
`authorization-status: provisional` while you are.

### How do I revoke / reset notification permission?

System Settings → Notifications → Roar → toggle **Allow
Notifications** off.

To reset to the first-run state programmatically:

```sh
defaults delete io.myers.roar
killall usernoted   # respawned by launchd
```

The next `roar send` will request provisional auth again as
if it were a fresh install.

## Behaviour & scope

### Can I attach an HTTP URL directly to a notification?

No. `--attachment` accepts local paths only. Pre-download:

```sh
curl -fsSL -o /tmp/poster.png 'https://…/poster.png'
roar send --title "New release" --attachment /tmp/poster.png
```

Supporting remote fetch requires maintaining an HTTP client (SSRF screening,
size caps, redirect guard, etc.) inside a CLI tool that the user can
replace with one `curl` invocation.

### Can I send rich text / Markdown / HTML in the body?

No. macOS notifications are plain text; line breaks and tabs
render as printable whitespace, but every other glyph is
literal. There's no inline markup, no bold, no links inside the
body. (You can attach an image via `--attachment` and configure
a custom action via `--action`, but the body itself is text.)

### Can I send a notification to another user on the same machine?

No. Notifications are scoped to the logged-in user — Roar
posts to the *current* user's notification center, period. To
ping another user, `ssh` or `osascript` into their session and
run `roar` there.

### Can I send a notification to a different machine over the network?

No, not directly. Roar runs locally and `usernoted` is a
per-user daemon. Common workarounds:

- Run Roar over SSH to the target machine.
- Use a remote-notification service (Pushover, ntfy.sh, Apple
  Push Notifications) — outside Roar's scope.

### What happens if I send two notifications with the same `--identifier`?

The second replaces the first in place — no flicker, no
duplicate in Notification Center, no second sound. This is the
design intent of `--identifier`: it's a stable handle for an
updating notification (build progress, status pings,
in-flight state). Omit the flag to mint a fresh UUID per send,
and successive notifications accumulate.

### Why is there a 4 KB cap on `--title` / `--subtitle` / `--body`?

To bound the XPC payload that ships to `usernoted` and to
surface a clear error when someone pipes untrusted input
(`roar send --title "$REMOTE_DATA"`) without bounding it
upstream. Plain UN would accept arbitrarily long fields and
fail at the XPC bridge with an opaque error; Roar's cap fails
fast with a clear diagnostic.

### Why no `--critical` interruption level?

Apple reserves `.critical` for entitlements (`com.apple.developer.usernotifications.critical-alerts`)
granted only to apps Apple has individually approved. An
ad-hoc-signed CLI like Roar cannot claim the entitlement, so
the value would be silently demoted at runtime. We expose
`passive` / `active` / `time-sensitive`; that's the full set
available to an unentitled bundle.

### Why does `--exec` need `--allow-shell-on-click`?

To make the click-to-shell-command surface impossible to miss.
In an invocation like
`roar send --title "Build complete" --exec 'curl https://…|sh'`,
the danger isn't obvious from the title alone — a casual reader
might miss `--exec` entirely. Requiring `--allow-shell-on-click`
forces the user (or a code reviewer reading a CI YAML) to
explicitly acknowledge what they're wiring up. See
[Security](SECURITY.md#2-shell-on-click-consent-gate-exec).

### Why does Roar reject `--at` timestamps in the past?

Because macOS would fire them immediately, contradicting the
"scheduled" framing. Most pasts are typos: a year off, an
ISO timestamp from a script that drifted, a wrong timezone
offset. Rejecting them surfaces the mistake at send time
rather than producing a notification the user didn't expect.
See [Reference → `--at`](reference/send.md#-at-timestamp).

## Scripting

### How do I read the user's response in a script?

Use `--wait`. Roar blocks until the user interacts, then prints
the chosen action's id (and any typed text) to stdout. Exit
codes distinguish the four terminal states: 0 for click /
custom action, 2 for timeout, 3 for explicit dismiss, 1 for
runtime error. Full protocol in [Scripting](SCRIPTING.md).

```sh
choice=$(roar send --title "Deploy?" \
    --action go:Go --action stop:Stop::destructive \
    --wait --wait-timeout 30s)
echo "you picked: $choice"
```

### Can `roar` run inside `tmux` or `screen`?

Yes. Roar doesn't care about its parent TTY — it sends the
request over XPC to `usernoted`, which delivers the
notification regardless of how Roar was invoked. Notifications
fire even from a detached `tmux` session.

### Does `roar` work over SSH?

Yes, provided the SSH session has a logged-in user whose
NotificationCenter is running (i.e. someone is graphically
logged in on the remote console). It will NOT work if you SSH
into a Mac where nobody is logged in via the Aqua console —
`usernoted` only runs in a graphical user session.

### Can I run `roar` from `cron` / `launchd`?

Yes — that's a designed-for case. The provisional-auth model
exists specifically so unattended scripts can post without
hitting a permission dialog. For `launchd` specifically:

- The job must run under your user agent (`~/Library/LaunchAgents/...`,
  not `LaunchDaemons`), so it inherits your `usernoted` session.
- The first-run notification posts under provisional auth
  (quiet — see "Why doesn't my notification have a banner?"
  above). Tap **Keep** once to promote.

```xml
<!-- ~/Library/LaunchAgents/com.example.standup.plist -->
<plist version="1.0"><dict>
  <key>Label</key>           <string>com.example.standup</string>
  <key>ProgramArguments</key> <array>
    <string>/opt/homebrew/bin/roar</string>
    <string>send</string>
    <string>--title</string><string>Standup in 5 min</string>
  </array>
  <key>StartCalendarInterval</key><dict>
    <key>Weekday</key><integer>1</integer>   <!-- 0 or 7 = Sunday, 1 = Monday, ..., 6 = Saturday -->
    <key>Hour</key><integer>8</integer>
    <key>Minute</key><integer>55</integer>
  </dict>
</dict></plist>
```

### Is `roar list`'s TSV format an ABI I can rely on?

Yes. The TSV column layout is documented in
[Reference → `roar list` output format](reference/list.md#output-format)
and is treated as ABI for scripting purposes. Adding columns
to the right would be a minor-version break; removing or
re-ordering would be major.

### Can I parse Roar's output as JSON instead of text?

Yes. Every subcommand accepts `--json`:

```sh
roar list --json | jq -r '.[].identifier'
roar settings --json | jq -r '."authorization-status"'

choice=$(roar send --wait --title "Deploy?" \
    --action go:Go --action stop:Stop --wait-timeout 30s --json)
case "$(jq -r .outcome <<<"$choice")" in
    click)   echo "user picked $(jq -r .action <<<"$choice")" ;;
    dismiss) echo "rejected" ;;
    timeout) echo "no answer" ;;
esac
```

Exit codes are unchanged from text mode, so scripts that branch
on `$?` keep working. Per-subcommand schemas live on each
[reference page](reference/index.md) under "JSON output"; the
cross-cutting overview is in
[Scripting → JSON output](SCRIPTING.md#json-output-json). All
schemas are treated as stable ABI.

### Is there a Python / Ruby / Node.js library?

No first-party library; `roar` is a CLI, and the `--wait`
stdout protocol is a deliberately simple line-based format
designed to be readable from any subprocess-spawning runtime.
[Scripting → Python integration](SCRIPTING.md#python-integration)
has a worked example.

## Security & threat model

### Why does the notification icon limitation exist?

See "Why does the notification show the Terminal icon" above.
Short version: macOS's `responsible_pid` attribution.

### Can another process forge a notification under Roar's name?

Yes, if it runs as the same user — that's inherent to the
ad-hoc-signed local-CLI threat model. macOS doesn't scope
notification delivery by process identity, so any same-user
process posting under bundle id `io.myers.roar` can craft a
notification, including one whose userInfo asks the click
handler to exec a command. The `--allow-shell-on-click` opt-in
is enforced at send time, not at click time, so a spoofer can
set the userInfo flag too. The full discussion (and why an
HMAC-style fix doesn't help here) is in
[Security → same-bundle-id spoofing](SECURITY.md#3-same-bundle-id-spoofing-whats-in-scope-what-isnt).

### Why is `--allow-url-scheme` so strict?

Because some macOS URL schemes have click-time effects that
aren't obvious — `javascript:` runs script in the default
browser; `file:` hands the click to LaunchServices (which auto-
opens `.command` / `.app` payloads); `applescript:` runs
scripts; etc. Defaulting to an allow-list (http, https, mailto)
and requiring each addition to be explicit means a script that
slowly accumulates `--allow-url-scheme tel`,
`--allow-url-scheme vscode`, etc. forces the maintainer to
think about each one. See [Reference →
`--allow-url-scheme`](reference/send.md#-allow-url-scheme-scheme-repeatable).

### Why do attachments require local paths?

`--attachment` only takes local filesystem paths — no
`http://` URLs. Maintaining a remote-fetch path inside a CLI
tool requires an HTTP client, an SSRF-screening allow-list, a
size cap, a redirect guard, etc., all of which the user can
replace with `curl -o /tmp/file URL`. 

For the symlink / control-character / path-walk hardening
applied to local paths, see
[Security → attachment hardening](SECURITY.md#4-attachment-hardening).

## Bundle internals

For the on-disk layout of the installed `.app`, where Roar's
notifications live (inside `usernoted`'s per-user database, not
in Roar), and what `brew uninstall --cask --zap` removes, see
[Reference → Installed layout](reference/index.md#installed-layout).

## Contributing

### How do I build Roar from source?

See [BUILD.md](BUILD.md). Short version:

```sh
git clone https://github.com/dalemyers/Roar.git && cd Roar
brew install xcodegen
xcodegen generate
xcodebuild -project Roar.xcodeproj -scheme roar -configuration Release build
```

### Where do I file a bug?

GitHub issues at https://github.com/dalemyers/Roar/issues. For
security issues see [Security → reporting](SECURITY.md#reporting-a-vulnerability).

### How do I propose a feature?

Open a GitHub issue describing the use case (not just the
proposed flag). The project's design preference is for *narrow,
composable* flags over wide-surface ones; concrete use cases
help calibrate whether a feature is in scope.
