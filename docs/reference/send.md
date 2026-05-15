# `roar send`

The workhorse. Posts a single notification, with optional click
handlers, scheduling, custom buttons, attachments, foreground-
presentation tuning, and a `--wait` mode that blocks until the
user interacts.

Flags are grouped by purpose below. `--body` is required (either
as a direct argument or piped on stdin); every other flag is
optional, with `--title` defaulting to the machine's user-visible
name.

## Content

### `--title <string>`

Notification title. Defaults to the machine's user-visible name
from **System Settings → General → About → Name**, falling back to
the short hostname when that lookup fails.

- **Validation:** rejects NUL bytes (would truncate at the XPC
  bridge); 4 KB UTF-8 byte cap. Newlines and tabs are accepted —
  macOS renders them as printable whitespace.

```sh
roar send --title "Build complete" --body "succeeded in 4m23s"
```

### `--subtitle <string>`

A second line under the title in the banner / Notification
Center entry. Same validation as `--title`.

```sh
roar send --title "Deploy" --subtitle "production · us-east-1" --body "v3.2.0"
```

### `--body <string>` / `-b <string>`

The main message body. If omitted **and** stdin is piped, the
body is read from stdin (up to a 1 MB cap, per
[Security](../SECURITY.md#11-stdin-cap)). 4 KB UTF-8 byte cap
on the resolved value, whether sourced from the flag or stdin.

```sh
# direct
roar send --title "Build" --body "succeeded in 4m23s"

# stdin (omit --body; Roar reads piped input automatically)
git log -1 --pretty=%B | roar send --title "Last commit"
```

`--body -` is **not** a special stdin marker — it would set the
body to the literal string `-`. To use stdin, omit `--body`
entirely.

### `--sound <name>`

A system sound name from `/System/Library/Sounds/` or
`/Library/Sounds/` (e.g. `Glass`, `Hero`, `Submarine`, `Tink`),
or the literal string `default` for the system's default
notification sound. Roar validates the name against an `.aiff` /
`.caf` file in those two directories before submitting.

`~/Library/Sounds/` is **not** consulted: the
`UNNotificationSound(named:)` framework call doesn't resolve names
from the user's home directory, so including it would let
validation pass while the notification played silently. See
[Troubleshooting → silent sound](../TROUBLESHOOTING.md#i-see-the-notification-but-it-doesnt-play-a-sound).

```sh
roar send --title "Done" --body "Build finished" --sound Glass
roar send --title "Heads up" --body "Tap to view" --sound default
```

Note: under **provisional** notification authorization (the
default for first-run users), macOS silences sounds regardless
of this flag. See
[Concepts → provisional auth](../CONCEPTS.md#provisional-vs-full-authorization).

### `--identifier <id>`

Stable identifier for the notification. **Reposting with the
same identifier replaces the prior notification in place** —
no flicker, no duplicate in Notification Center, no second
sound. Omit to mint a fresh UUID per send.

Useful for: build progress, status pings, transient state
that should update rather than accumulate. See
[Cookbook → replace-in-place](../COOKBOOK.md#replace-in-place-updates).

- **Validation:** non-empty after trimming, no control
  characters, max 256 chars.

```sh
roar send --identifier build-status --title "Build" --body "30%"
# ... later, same id:
roar send --identifier build-status --title "Build" --body "60%"
```

## Click handlers

A click on the notification body triggers one of four click
behaviours, depending on which flags were set at send time:

| Flag | What happens on click |
|---|---|
| `--activate-bundle-id` | The named app is brought to the foreground. |
| `--open-url` | The URL is opened (re-validated against the pinned scheme allow-list). |
| `--exec` | The shell command runs via `/bin/sh -c` in a scrubbed environment. |
| `--wait` | The action id is written to stdout and `roar send` exits. |

`--wait` is mutually exclusive with `--activate-bundle-id`,
`--open-url`, and `--exec`: in wait mode the calling script is
responsible for the side effect after `roar` exits, based on the
printed id.

The other three (`--activate-bundle-id`, `--open-url`, `--exec`)
are **not** mutually exclusive at send time, but combining them is
unusual. The click handler runs whatever's set in this order:
activate → open → exec. Each runs even if a previous one failed.
Typical use is to set exactly one; if you find yourself reaching
for two, consider whether `--exec` calling `osascript`/`open` is a
clearer expression of intent.

### `--activate-bundle-id <bundle-id>`

Bring the named application to the foreground on click. The
value is a reverse-DNS bundle identifier like `com.apple.Safari`
or `com.googlecode.iterm2` — find one with
`osascript -e 'id of app "Safari"'`.

- **Validation:** non-empty, no control characters; max 256
  chars. The value is re-validated at click time so a spoofed
  notification can't sneak in a NUL.
- **Failure mode:** if the bundle id isn't installed,
  `urlForApplication(withBundleIdentifier:)` returns nil and the
  click exits non-zero. Run with `ROAR_DEBUG=1` to see which
  bundle id was rejected.

```sh
roar send --title "Switch to Safari" --body "Tap to focus" --activate-bundle-id com.apple.Safari
```

### `--open-url <url>`

URL to open on click. By default only `http`, `https`, and
`mailto` are accepted; any other scheme requires an explicit
`--allow-url-scheme` opt-in.

- **No "accept everything" override** by design. Some schemes
  carry significant click-time risk (`javascript:` /
  `data:` run script; `file:` / `afp:` / `smb:` hand
  attacker-controllable paths to LaunchServices; `applescript:`
  / `help:` have a long history of RCEs). See
  [Security → URL allow-list](../SECURITY.md#1-url-scheme-allow-list-open-url).
- **Credentials in URLs are rejected** (`user:pass@host`) — they
  would otherwise land in the notification's userInfo and in
  any error message.
- **Click-time re-parse:** the send-time allow-list is
  serialised into userInfo and replayed at click time, so a
  click can never broaden what the send agreed to.

```sh
roar send --title "PR #42 ready" --body "Click to review" \
    --open-url https://github.com/me/repo/pull/42
roar send --title "Email John" --body "Click to reply" \
    --open-url 'mailto:john@example.com?subject=Hi'
```

### `--allow-url-scheme <scheme>` *(repeatable)*

Add a URL scheme to the `--open-url` allow-list. Repeat for each
scheme. The default trio (`http`, `https`, `mailto`) is always
included.

```sh
roar send --title "Open in editor" --body "main.swift" \
    --open-url 'vscode://file//Users/me/code/main.swift' \
    --allow-url-scheme vscode

roar send --title "Join standup" --body "Tap to join" \
    --open-url 'zoommtg://zoom.us/join?confno=12345' \
    --allow-url-scheme zoommtg
```

Be deliberate. Adding `javascript`, `data`, `applescript`, or
`file` opts you into the click-to-script / click-to-RCE shape
of those handlers. The full risk catalogue is in
[Security → URL allow-list](../SECURITY.md#1-url-scheme-allow-list-open-url).

### `--exec <command>`

Shell command to run via `/bin/sh -c` on click. **Requires
`--allow-shell-on-click`** to avoid notifications like
"Build complete" silently carrying an unrelated payload.

- **NUL-byte rejection:** Send- and click-time. A NUL would
  truncate at `posix_spawn`'s `strdup`, hiding part of the
  command from the user's visible value. See
  [Security → control-char screening](../SECURITY.md#5-control-character-nul-screening).
- **Environment:** the spawned shell inherits a scrubbed
  environment with `PATH` pinned to the system default and the
  usual sensitive vars (`BASH_ENV`, `LD_*`, `DYLD_*`, `IFS`)
  filtered. See
  [Security → environment scrubbing](../SECURITY.md#2-shell-on-click-consent-gate-exec).
- **Working directory:** `$HOME`. The handler `cd`s there
  before `exec`-ing the command (a workaround for a macOS-26
  deprecation; see the comment in `Sources/ShellExecutor.swift`).
- **Timeout:** the child has 60 seconds to complete; after that
  the handler kills the process group and exits non-zero. Click
  handlers are meant for short follow-ups (open a file, kick off
  a build); anything longer should detach (`nohup`, `at`, a
  launchd job).

```sh
roar send --title "Build failed" --body "Click to rebuild" \
    --exec 'cd ~/code && make' --allow-shell-on-click
```

### `--allow-shell-on-click`

Opt-in flag required when `--exec` is set. Acknowledges the
click-to-shell-command surface. Without it, the validator
rejects `--exec`.

## Scheduling

`--in`, `--at`, and `--repeat` are mutually exclusive: pick at
most one. Omit all three for immediate delivery. The validator
rejects sub-1-second windows and dates further than 365 days
out — both as typo guards
([Security → schedule bounds](../SECURITY.md#8-schedule-bounds)).

### `--in <duration>`

Fire after a relative duration. Format: `<number><unit>` where
unit is `s` / `m` / `h` / `d`. Fractional values accepted
(`1.5h` = 90 minutes).

- **Range:** ≥ 1 second, ≤ 365 days.
- **Grammar pinned:** scientific notation (`1e5s`), hex
  literals (`0x1p3s`), and leading `+` signs are rejected.

```sh
roar send --title "Stretch" --body "Step away from the keyboard" --in 30m
roar send --title "Standup" --body "Meeting starts now" --in 1.5h
```

### `--at <timestamp>`

Fire at an absolute time. Accepted forms:

| Form | Example | Notes |
|---|---|---|
| ISO 8601 with zone | `2026-12-31T17:00:00Z` | unambiguous |
| ISO 8601 with offset | `2026-12-31T17:00:00+01:00` | unambiguous |
| ISO 8601 + ms | `2026-12-31T17:00:00.123Z` | fractional seconds preserved |
| Local time, T | `2026-12-31T17:00:00` | system's local zone |
| Local time, space | `2026-12-31 17:00:00` | system's local zone |
| Local time, no secs | `2026-12-31 17:00` | seconds default to 0 |
| Date only | `2026-12-31` | midnight in the local zone |

- **Validation:** past timestamps rejected with a distinct error
  from near-future-but-too-close timestamps; both messages name
  the floor explicitly.
- **DST + script portability:** prefer the zone-explicit shapes
  in scripts you share across machines.

```sh
roar send --title "Lunch" --body "Step away" --at '2026-05-15 12:30'
roar send --title "Year-end" --body "Happy new year" --at 2026-12-31T23:59:00Z
```

### `--repeat <pattern>`

Fire on a recurring calendar pattern. Accepted shapes:

| Pattern | Fires |
|---|---|
| `hourly` | At minute 0 of every hour |
| `daily:HH:MM` | Every day at HH:MM (24-hour, local) |
| `weekly:DAY:HH:MM` | Every week on DAY at HH:MM |
| `monthly:D:HH:MM` | Every month on day D at HH:MM |

`DAY` is one of `mon|tue|wed|thu|fri|sat|sun` (case-insensitive,
locale-stable). `D` is `1..31`. **`monthly:31:*` is accepted but
silently skips months with fewer than 31 days** — UN's
documented behaviour.

```sh
roar send --title "Standup" --body "Meeting in 5 min" --repeat 'weekly:mon:09:00'
roar send --title "Rent due" --body "Pay before 10am" --repeat 'monthly:1:10:00'
```

Times are interpreted in `TimeZone.current` at fire time. The
weekday table is Gregorian-pinned, so users on non-Gregorian
system calendars still get the day they typed.

## Interaction (`--wait`)

### `--wait`

Block until the user interacts with the notification, then
print the chosen action's id (and any typed text) to stdout
and exit. The wait survives across the notification's full
lifecycle — banner, Notification Center entry, click, custom
button, or dismiss.

| User action | stdout | Exit code |
|---|---|---|
| Clicks the notification body | `default\n` | 0 |
| Clicks a custom button | `<button-id>\n` | 0 |
| Clicks a `--text-action` and submits | `<button-id>\n<typed text>\n` | 0 |
| Explicitly dismisses | `dismiss\n` | 3 |
| `--wait-timeout` elapses | `timeout\n` | 2 |

Mutually exclusive with `--exec`, `--open-url`, and
`--activate-bundle-id` (the calling script handles side
effects after `roar` exits, based on the printed id). The
typed text in the `--text-action` case may contain newlines
and arbitrary bytes — **read to EOF, not line-by-line**.

For the full stdout protocol and shell / Python / CI patterns,
see [Scripting](../SCRIPTING.md).

```sh
choice=$(roar send --title "Deploy?" --body "Push v3.2.0 to prod?" \
    --action approve:Approve \
    --action reject:Reject::destructive \
    --wait --wait-timeout 30s)
case "$choice" in
    approve) ./deploy.sh ;;
    reject)  echo "user rejected" ;;
    timeout) echo "no answer in 30s" ;;
esac
```

### `--wait-timeout <duration>`

Maximum time `--wait` will block. Same grammar as `--in`
(`30s`, `5m`, `2h`, etc.). Defaults to `5m` when `--wait` is
set, so unattended scripts can't hang forever. Max is 365 days.

On timeout, `timeout\n` is printed to stdout and the process
exits with code 2.

## Custom actions (require `--wait`)

### `--action <id>:<title>[::<flags>]` *(repeatable, max 4)*

Add a custom button to the notification. Syntax:
`<id>:<title>::<comma-separated-flags>`.

- **id**: opaque short string; printed on stdout when clicked.
- **title**: button label (free-form, screened for NUL).
- **flags** (optional, after `::`):
  - `destructive` — the title renders in red.
  - `auth-required` — the user must unlock the device before
    the click is delivered.

The UN `.foreground` option is not exposed — `roar` is an
`LSUIElement: true` bundle with no window, so it would do
nothing.

**Reserved ids:** `default` and `dismiss` are rejected at parse
time because they collide with the
[`--wait` stdout protocol](../SCRIPTING.md#the-wait-stdout-protocol)'s
default-click / explicit-dismiss sentinels. Avoid `timeout` too:
it isn't currently rejected, but a user-defined `--action timeout:...`
prints the same stdout line (`timeout\n`) as the `--wait-timeout`
expiry sentinel — the exit code disambiguates (0 for the click,
2 for the timeout), but shell scripts that branch on stdout
alone will conflate the two.

```sh
roar send --title "Delete this branch?" --body "feature/old-prototype" \
    --action confirm:Delete::destructive,auth-required \
    --action cancel:Cancel \
    --wait
```

### `--text-action <id>:<title>[::<flags>]` *(at most one)*

Add a text-input ("reply") action. Same syntax as `--action`,
same reserved-id list. Only one per notification.

On submit, `roar` prints `<id>\n<typed-text>\n` to stdout and
exits 0. The typed text is forwarded **verbatim** — newlines,
NUL bytes, multi-byte UTF-8 — so receivers should read to EOF
rather than line-by-line.

```sh
reply=$(roar send --title "Quick note?" --body "Capture today's thought" \
    --text-action capture:Add \
    --text-placeholder "Type your note..." \
    --wait)
note=$(printf '%s' "$reply" | tail -n +2)
```

### `--text-placeholder <string>`

Placeholder text shown inside the reply field. No effect
without `--text-action`. Default: empty.

### `--text-button-title <string>`

Label of the inline submit button next to the reply field. No
effect without `--text-action`. Default: the system value
(typically "Send"). Pass `""` to keep the system default.

## Display behaviour

### `--interruption-level <level>`

How disruptive the notification should be:

| Level | Behaviour |
|---|---|
| `passive` | Lands in Notification Center silently; no banner, no Focus break-through. |
| `active` (default) | Standard banner + NC behaviour. |
| `time-sensitive` | Attempts to bypass Focus / Do Not Disturb. Requires the user to allow time-sensitive in System Settings → Notifications → Roar. |

`critical` is intentionally not exposed — it requires a
paid Apple entitlement that an ad-hoc-signed CLI cannot claim.

See [Cookbook → focus](../COOKBOOK.md#focus-and-do-not-disturb) for
how to wire time-sensitive notifications past Focus.

```sh
roar send --title "Coffee's ready" --body "Tap when you grab it" \
    --interruption-level passive
roar send --title "Server alert" --body "CPU at 95% for 5 min" \
    --interruption-level time-sensitive
```

### `--relevance-score <0.0-1.0>`

Importance hint between `0.0` and `1.0`. Higher values rank the
notification more prominently when Notification Center groups
collapse multiple entries into a summary. NaN / Infinity / out-of-
range values are rejected.

```sh
roar send --title "Server alert" --body "CPU at 95%" --relevance-score 1.0
```

### `--foreground-presentation <option>` *(repeatable)*

How the notification should appear if it arrives while `roar`
itself is still running in the foreground (typically only the
`--wait` flow — `roar send` without `--wait` exits within
~100ms of `add(_:)` returning). Repeatable; valid values:

| Value | Effect |
|---|---|
| `banner` | Show the banner |
| `list` | Add to Notification Center |
| `sound` | Play the configured sound |

When the flag is omitted entirely, `roar` uses
`banner+list+sound`. The literal value `none` is
**rejected** because an invisible-but-clickable notification is
a phishing vector — use `--interruption-level passive` instead
to suppress attention-grabbing presentation.

The setting has no effect on notifications delivered after
`roar` has exited — those go through the system's default
presentation routing.

```sh
roar send --title "Quiet click" --body "Pick a button" \
    --foreground-presentation list \
    --wait
```

## Grouping & category metadata

### `--thread-id <id>`

Group related notifications under a single banner stack. Same
validation as `--identifier` (non-empty, no control chars, 256
char max).

```sh
roar send --title "PR #1 ready" --body "feat/login flow" --thread-id pr-reviews
roar send --title "PR #2 ready" --body "fix/logout flow" --thread-id pr-reviews
```

### `--summary-format <format-string>`

Format string for the summary line macOS renders when multiple
notifications in this category collapse together. Tokens:

- `%u` — unread count
- `%@` — comma-joined list of intent identifiers

```sh
roar send --title "New PR" --body "feat/billing" \
    --thread-id pr-reviews \
    --summary-format '%u new pull requests'
```

### `--target-content-id <id>`

Hint string handed to the target app on click, used to route the
click to a specific window or document. Same validation as
`--identifier`. Mostly useful when combined with
`--activate-bundle-id` for apps that consume the hint via
`UNNotificationContentExtension`.

```sh
roar send --title "Reply to thread" --body "From: Alex" \
    --activate-bundle-id com.apple.MobileSMS \
    --target-content-id thread-abc123
```

## Attachments

### `--attachment <path>` *(repeatable)*

Local filesystem path to an image, audio file, or video. **Local
paths only** — `--attachment` does not fetch URLs; pre-download
remote content with `curl -o /tmp/file URL` and pass the
resulting path.

Repeat the flag for multiple attachments. macOS caps the visible
count per notification, but extras still ride along in the
post (e.g. for `UNNotificationContentExtension` to access).

**Hardening:** symbolic links at the leaf and at every
intermediate component are rejected (except for the
`/tmp`, `/var`, `/etc` system symlinks), `realpath` is run to
canonicalise the path, and the final `.localPath` is re-screened
for control characters. See
[Security → attachment hardening](../SECURITY.md#4-attachment-hardening).

```sh
roar send --title "Build result" --body "All tests passed" \
    --attachment ~/builds/result.png
roar send --title "Photoshoot" --body "Three picks" \
    --attachment shot1.jpg --attachment shot2.jpg --attachment shot3.jpg
```

### `--attachment-type-hint <uti>`

A Uniform Type Identifier (e.g. `public.png`, `public.mpeg-4`,
`public.jpeg`) telling UN how to interpret the attachment. Use
when the file's extension is misleading or absent — the
framework otherwise infers type from the filename. Applies
uniformly to every `--attachment` in the invocation.

```sh
roar send --title "Capture" --body "Screenshot ready" \
    --attachment /tmp/screenshot-no-extension \
    --attachment-type-hint public.png
```

### `--no-thumbnail`

Suppress the small thumbnail preview macOS renders alongside the
attachment in Notification Center. The full attachment is still
delivered; only the preview glyph is hidden.

### `--thumbnail-time <seconds>`

For video attachments only: the seconds-offset into the video
to use for thumbnail generation. Non-negative finite double.
Ignored for image attachments.

```sh
roar send --title "Build demo" --body "Tap to play" \
    --attachment ~/builds/demo.mp4 \
    --thumbnail-time 3.5
```

## Lock-screen privacy

The user controls a global "Show Previews" setting in **System
Settings → Notifications**: *Always*, *When Unlocked*, or
*Never*. The flags below shape what appears on a locked screen
under the latter two settings, letting sensitive content
(auth codes, private messages) post safely without leaking on
the lock screen.

### `--hide-previews-body-placeholder <string>`

Placeholder body shown when previews are hidden. The real body
is delivered normally and visible after unlock; the placeholder
is what shows on the lock screen.

```sh
roar send --title "Login code" --body "123456" \
    --hide-previews-body-placeholder "Tap to unlock"
```

### `--show-title-when-previews-hidden`

Boolean flag. Show the title on the lock screen even when
previews are hidden. Without this flag, macOS replaces the
title with the bundle name (`Roar`) when previews are off.

### `--show-subtitle-when-previews-hidden`

Boolean flag. Show the subtitle on the lock screen even when
previews are hidden. Without this flag, macOS suppresses the
subtitle entirely under previews-hidden.

## Focus filtering

### `--filter-criteria <string>`

Hint handed to the framework via
`UNMutableNotificationContent.filterCriteria`. Used by Focus
filters (configured per-user in System Settings → Focus) to
decide whether a notification breaks through the current Focus.

Free-form within the same envelope as the other XPC routing keys:
non-empty after trimming, no control characters, max 256
characters. UN itself does no further validation — the value is
matched verbatim against whatever Focus filter the user has
configured. Common shapes are conversation identifiers (for chat
apps), priority labels, or a domain string the user has matched
in their Focus filter rules.

```sh
roar send --title "PR review" --body "Tap to open" --filter-criteria work
```

## JSON output (`--json`)

Pass `--json` to emit a JSON object on stdout instead of text /
silence. Two shapes, depending on whether `--wait` is in play.

### Non-wait

The text path is silent on success. With `--json`, `roar send`
prints a single object confirming the post:

```json
{"identifier": "abc-123", "posted": true}
```

| Field | Type | Notes |
|---|---|---|
| `identifier` | string | The value you passed via `--identifier`, or the UUID Roar minted if you didn't. Useful for downstream `roar dismiss "$id"` or replace-in-place reposts. |
| `posted` | boolean | Always `true` on success — failures throw and exit non-zero, the JSON shape never carries `"posted": false`. |

```sh
# Capture the minted identifier for a follow-up dismiss
id=$(roar send --title "Build…" --body "running" --json | jq -r .identifier)
# later:
roar dismiss "$id"
```

### `--wait`

A single JSON object representing the terminal outcome. Replaces
the line-oriented text protocol (`<action>\n` or
`<action>\n<text>\n`).

```json
{"action": "default", "outcome": "click", "text": null}
```

| Field | Type | Notes |
|---|---|---|
| `outcome` | `"click"` \| `"dismiss"` \| `"timeout"` | Coarse-grained verdict. Most scripts that previously switched on the text protocol's four shapes can `case` on this alone. |
| `action` | string | The action identifier. Reserved sentinels: `default` (body click), `dismiss` (explicit dismiss), `timeout` (timeout fired). Custom `--action` ids pass through verbatim. |
| `text` | string \| `null` | Typed text for a `--text-action` submission; `null` for every other outcome. JSON string-escaping handles embedded newlines and arbitrary bytes — the text protocol's "read to EOF" workaround isn't needed. |

Exit codes are unchanged across output modes:
`waitDismissExitCode` (3), `waitTimeoutExitCode` (2), 0 on
matched click. Scripts using `$?` work identically; scripts
using `jq -r '.outcome'` get a single token to switch on.

The schema is stable scripting ABI — fields may be added, but
renames or removals are major-version breaks. `text` always
appears as either a string or `null`, never omitted, so
`jq '.text'` always returns a value.

```sh
# Switch on the coarse outcome
r=$(roar send --title "Deploy?" --action go:Go --action stop:Stop \
        --wait --wait-timeout 30s --json)
case "$(jq -r '.outcome' <<<"$r")" in
    click)
        action=$(jq -r '.action' <<<"$r")
        echo "user picked $action"
        ;;
    dismiss) echo "user said no" ;;
    timeout) echo "no answer in 30s" ;;
esac

# Pull the typed text out of a --text-action reply
reply=$(roar send --title "Note?" --text-action note:Add --wait --json)
note=$(jq -r '.text' <<<"$reply")
```
