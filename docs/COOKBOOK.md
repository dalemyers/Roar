# Roar Cookbook

Recipes for common workflows. Each example is self-contained — copy,
edit, run.

> Conventions used below:
> - Title defaults to the machine's user-visible name (System
>   Settings → General → About → Name), so you'll see it on the
>   banner without setting `--title`.
> - `$?` is the exit code of the last command. See
>   [SCRIPTING.md](SCRIPTING.md) for the full table.
> - Examples assume `roar` is on your `PATH`.

## Build status

### Notify when a long-running build finishes

```sh
if make; then
    roar send --body "Build OK"
else
    roar send --body "Build FAILED"
fi
```

(The terser `make && roar send "OK" || roar send "FAILED"` form
looks right but has a precedence trap: if `make` succeeds *and*
the first `roar send` fails — e.g. notification permission was
denied — the "FAILED" branch fires too. The `if/then/else` form
ties the branch to `make`'s exit code alone.)

### Use the last line of the build log as the body

```sh
log=$(make 2>&1 | tee build.log | tail -n 1)
roar send --title "Build" --body "$log"
```

### Pipe the body from stdin

`--body -` is not a special value — Roar reads stdin automatically
when `--body` is omitted and stdin is piped:

```sh
make 2>&1 | tail -n 5 | roar send --title "Build complete"
```

Cap is 1 MB. A pipe whose writer keeps writing past the cap is
**rejected** with a `ValidationError` so a runaway pipe can't
blow up memory or silently drop bytes. The edge case is a writer
that fills the cap and then pauses *without* closing the pipe:
Roar `poll(2)`s briefly, and if the writer hasn't either closed
or produced more bytes by the time the probe times out, Roar
emits a "possibly truncated" warning on stderr (rather than
blocking the CLI indefinitely waiting for the writer to commit).
The body up to the cap is still posted.

## Replace-in-place updates

Use the same `--identifier` to update a notification in place — no
flicker, no duplicate sounds, no second NC entry.

### Progress bar

```sh
roar send --identifier build --body "Build 1/4: lint"
roar send --identifier build --body "Build 2/4: compile"
roar send --identifier build --body "Build 3/4: test"
roar send --identifier build --body "Build 4/4: package"
```

### Watch a status file

```sh
while sleep 5; do
    status=$(curl -s https://ci.example.com/status/$JOB_ID)
    roar send --identifier ci-$JOB_ID --body "CI: $status"
    [[ "$status" =~ (passed|failed) ]] && break
done
```

## Scheduled notifications

### Fire in five minutes

```sh
roar send --body "Stand-up starting" --in 5m
```

`--in` accepts `<number><unit>` where unit is `s` / `m` / `h` / `d`.
Floating point is fine (`1.5h`). Minimum 1s, maximum 365d.

### Fire at a specific local time

```sh
roar send --body "Coffee break" --at "2026-12-31 15:00"
roar send --body "New Year"     --at "2027-01-01"           # midnight local
roar send --body "Backup"       --at "2026-12-31T03:00:00Z" # UTC
```

Accepted forms:

- ISO 8601 with zone: `2026-12-31T17:00:00Z`, `2026-12-31T17:00:00+01:00`
- Local time T-separator: `2026-12-31T17:00:00`
- Local time space-separator: `2026-12-31 17:00:00`
- Local time without seconds: `2026-12-31 17:00`
- Date-only at local midnight: `2026-12-31`

Past timestamps and timestamps less than 1 second away are rejected
(the old behaviour silently clamped to `now + 1s`, breaking the
"fires at the timestamp I provided" contract).

### Recurring schedules

```sh
roar send --body "Top of hour"   --repeat hourly
roar send --body "Daily stand-up" --repeat daily:09:30
roar send --body "Weekly review" --repeat weekly:fri:16:00
roar send --body "Pay rent"      --repeat monthly:1:09:00
```

The recurring trigger fires until the user explicitly dismisses
the schedule, or until you cancel it via `roar clear --pending`
(scheduled bucket only) or `roar clear --all` (delivered AND
pending). The two are mutually exclusive — pick one. Days-of-week
are `mon`/`tue`/`wed`/`thu`/`fri`/`sat`/`sun` (any case; lowercase
shown here for consistency). HH is 0..23 (24-hour), MM is 0..59.
`monthly:31:...` is allowed — months without a 31st are silently
skipped by the framework.

## Click handlers

### Open a URL on click

```sh
roar send --body "PR is ready" \
    --open-url "https://github.com/example/example/pull/42"
```

Only `http`, `https`, `mailto` are allowed by default. Other schemes
must be opted in explicitly, one at a time:

```sh
roar send --body "Open in editor" \
    --open-url "vscode://file//Users/me/code/main.swift" \
    --allow-url-scheme vscode
```

The two-flag shape isn't ceremony — it's a guard for the script
case where the URL comes from a variable (CI output, webhook,
env var) and might unexpectedly carry a dangerous scheme. Full
rationale, including what the gate does NOT defend against, is
in [Security → URL scheme allow-list](SECURITY.md#1-url-scheme-allow-list-open-url).

Repeat `--allow-url-scheme` for each scheme you want to accept:

```sh
roar send --body "Call?" \
    --open-url "tel:+1234567890" \
    --allow-url-scheme tel \
    --allow-url-scheme sms
```

### Run a shell command on click

```sh
roar send --body "Coffee timer expired — click to dismiss" \
    --exec "afplay /System/Library/Sounds/Glass.aiff" \
    --allow-shell-on-click
```

`--exec` requires `--allow-shell-on-click` — a `Build complete`
notification could otherwise quietly carry an unrelated shell
payload. The handler runs the command through `/bin/sh -c` after
spawning into a clean signal mask.

### Activate an application on click

```sh
roar send --body "Mail from boss"   --activate-bundle-id com.apple.mail
roar send --body "Slack message"    --activate-bundle-id com.tinyspeck.slackmacgap
```

Use `lsappinfo list` or `osascript -e 'id of app "Safari"'` to find
bundle ids.

## Replyable prompts (interactive `--wait`)

### Yes/no decision in a script

```sh
choice=$(roar send --wait \
    --title "Deploy?" \
    --body "Push v3.2.0 to production?" \
    --action ok:Approve \
    --action no:Reject::destructive)

case "$choice" in
    ok)      ./deploy.sh ;;
    no)      echo "deployment cancelled by user" ;;
    dismiss) echo "user swipe-dismissed; exit was 3" ;;
    timeout) echo "no answer in 5 min; exit was 2" ;;
esac
```

`--action`'s grammar is `id:title[::flag,flag]`. Supported flags:
`destructive` (red title) and `auth-required` (user must unlock
the device before the action fires).

### Text-input (reply-style) action

```sh
output=$(roar send --wait \
    --title "Quick note" \
    --body "What did you work on today?" \
    --text-action save:Save \
    --text-placeholder "your day in 1-2 lines" \
    --text-button-title Save)

# stdout layout: "<action_id>\n<typed text>\n"
# The typed text can contain newlines and arbitrary bytes — read to
# EOF, not line-by-line.
action=$(printf '%s' "$output" | head -n 1)
text=$(printf '%s' "$output" | tail -n +2)
echo "action: $action"
echo "text:   $text"
```

### Setting a wait timeout

```sh
# Default --wait-timeout is 5 minutes.
roar send --wait --body "Press a button" --wait-timeout 30s
roar send --wait --body "Take your time" --wait-timeout 1h
```

If the timeout elapses Roar prints `timeout` and exits 2.

## Attachments

### Single image

```sh
roar send --body "Screenshot ready" \
    --attachment ~/Desktop/screenshot.png
```

### Multiple attachments

```sh
roar send --body "Snapshots" \
    --attachment /tmp/before.png \
    --attachment /tmp/after.png
```

The system caps the visible thumbnail count per notification, but
all attachments ride along in the payload and are accessible via the
notification's extended view.

### Video with a specific thumbnail frame

```sh
roar send --body "Highlight reel" \
    --attachment ~/Movies/clip.mp4 \
    --thumbnail-time 12.5    # frame at 12.5 seconds
```

### Hide the thumbnail entirely

```sh
roar send --body "Attached log" \
    --attachment /tmp/build.log \
    --no-thumbnail \
    --attachment-type-hint public.plain-text
```

`--attachment-type-hint` accepts a UTI (`public.png`,
`public.mpeg-4`, etc.) — useful when the file's extension lies or is
absent.

### Pre-download a remote URL

`--attachment` accepts local paths only. For a remote URL:

```sh
curl -fsSL -o /tmp/avatar.jpg "https://example.com/avatar.jpg"
roar send --body "New avatar" --attachment /tmp/avatar.jpg
rm /tmp/avatar.jpg
```

## Listing and removing notifications

### Show everything roar has posted

```sh
roar list                        # delivered + pending
roar list --delivered            # just delivered
roar list --pending              # just scheduled
roar list --header               # add a TSV header row
```

Output is tab-separated. See
[Reference → roar list output format](reference/list.md#output-format)
for the canonical column list, types, and the `(unscheduled)`
placeholder for triggers without a next fire date.

### Find a notification with awk

```sh
roar list --delivered --header | awk -F'\t' '$1 == "build"'
```

### Remove by identifier

```sh
roar dismiss build
roar dismiss old-1 old-2 old-3
```

Unknown identifiers are reported to stderr by name. If **none** of
the supplied ids matched a notification, the exit code is `4`
(distinct from `0` so scripts can tell the difference).

### Mass-clear

```sh
roar clear                       # delivered only (safer default)
roar clear --pending             # cancel scheduled requests
roar clear --all                 # delivered AND pending
```

`roar clear` no longer destroys scheduled notifications without
`--all`. A typo'd `roar clear` from the shell prompt only flushes
the Notification Center bucket.

### Prune unused dynamic categories

Every `roar send` with `--action`/`--text-action` registers a
`roar.dyn.<hash>` category with the OS. The set grows monotonically
unless you prune:

```sh
roar clear --categories          # prune categories not referenced
                                 # by current notifications
roar clear --all --categories    # clear everything, then prune
```

The prune uses a double-snapshot protocol so a concurrent `roar
send` doesn't get clobbered.

## In CI

### Notify on job completion

```yaml
# .github/workflows/ci.yml
- name: Notify on failure
  if: failure() && runner.os == 'macOS'
  run: |
    roar send \
      --title "CI failed: ${{ github.workflow }}" \
      --body "${{ github.event.head_commit.message }}" \
      --open-url "${{ github.event.head_commit.url }}" \
      --interruption-level time-sensitive
```

Self-hosted macOS runners only — GitHub-hosted runners don't have
Roar installed.

### Make sure the runner isn't blocked by a permission dialog

On a fresh runner, Roar's first invocation will request provisional
authorization silently — no dialog will appear and `roar send` will
return immediately. The downside is that the resulting notifications
post quietly to Notification Center (no banner, no sound). For an
unattended runner that's usually fine.

### Bound a `--wait` to avoid runaway jobs

The default 5-minute `--wait-timeout` already protects you, but you
can shorten it:

```sh
roar send --wait --wait-timeout 30s \
    --title "Manual approval needed" \
    --action ok:Approve --action no:Reject
# Exit 2 = timeout, runner moves on.
```

## Focus and Do-Not-Disturb

### Break through Focus

```sh
roar send --body "Server is on fire" \
    --interruption-level time-sensitive
```

`time-sensitive` is the only level that bypasses Focus / Do Not
Disturb (the user can disable that per-app in
System Settings → Notifications → Roar → Time Sensitive
Notifications). Use sparingly — the `.critical` level is gated
behind an Apple-granted entitlement that an ad-hoc-signed CLI
cannot claim.

### Suppress break-through without going silent

```sh
roar send --body "FYI"  --interruption-level passive
```

`passive` posts to Notification Center but never raises a banner or
plays a sound. Use this for low-priority background pings (build
status updates, queue depth) that the user can look at when they
have a moment.

### Hint at a Focus filter

```sh
roar send --body "Customer support escalation" \
    --filter-criteria "support-escalation"
```

`--filter-criteria` is a free-form string the user's Focus filters
can match on (e.g. "let support pages through during my Work focus"
configured in Settings).

## Threading and grouping

```sh
roar send --body "PR opened"   --thread-id ci-12345
roar send --body "Tests green" --thread-id ci-12345
roar send --body "Merged"      --thread-id ci-12345
```

Same `--thread-id` groups notifications in the same row in
Notification Center. Use one thread per logical conversation /
build / ticket.

## Lock-screen privacy

If the user has set "Show Previews" to "When Unlocked" or "Never":

```sh
roar send \
    --title "Auth code" \
    --body "Your code is 123456" \
    --hide-previews-body-placeholder "Tap to view your auth code" \
    --show-title-when-previews-hidden
```

The body is replaced with the placeholder on the lock screen; the
title shows. Without `--show-title-when-previews-hidden` macOS
replaces the title with "Roar" too.

## Debug logging

Roar's click handler is silent by default so click-time URLs and
shell commands don't leak into the unified log. To see verbose
diagnostics, the variable has to be visible to launchd (which
spawns the click-handler process), not just to your shell. Set
it once per login session with `launchctl setenv`:

```sh
launchctl setenv ROAR_DEBUG 1
roar send --title "Click me" --body "Test" --open-url https://example.com
# Click the banner — verbose details on the workspace open, the
# scheme allow-list, etc. now land in the unified log.
log show --predicate 'process == "roar"' --info --last 5m

launchctl unsetenv ROAR_DEBUG   # when you're done
```

An inline `ROAR_DEBUG=1 roar send ...` only sets the variable for
the send-side process; the click-time relaunch is a separate
launchd-spawned process that won't see it.

## Cleanup

When you're done experimenting:

```sh
roar clear --all --categories
```

This wipes every delivered notification, cancels every scheduled
notification, and prunes every dynamic category Roar registered.
The notification permission record (granted vs denied) is **not**
touched — to reset that, toggle Allow Notifications in
System Settings → Notifications → Roar.
