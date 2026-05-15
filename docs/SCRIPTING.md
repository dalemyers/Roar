# Scripting with Roar

Roar is designed to be driven by other programs. This document
captures the contract every consumer can rely on:

1. **Exit codes** are stable and disjoint — branch on `$?`.
2. **`--wait` stdout** has a documented byte layout — read it
   programmatically, not visually.
3. **Validation** runs before any side effect — a `ValidationError`
   means nothing reached `usernoted`.

If you change any of these, you'll break shell scripts in the wild.
Treat them as the public ABI.

## Exit codes

| Code | Meaning                                                       | Source                |
|-----:|---------------------------------------------------------------|-----------------------|
| `0`  | Success. Notification posted; user clicked default or a custom action; `list`/`clear`/`settings` completed; at least one `dismiss` id matched. | Send / List / Clear / Settings / Wait |
| `1`  | Authorization denied or a click-time side effect failed.       | Send / `ensureAuthorized` / click handler |
| `2`  | `--wait-timeout` elapsed before the user interacted.           | Send `--wait` |
| `3`  | `--wait` mode and the user **explicitly dismissed** the notification (swipe, "X", right-click → close). | Send `--wait` |
| `4`  | `roar dismiss` and **none** of the supplied identifiers matched any delivered or pending notification. | Dismiss |
| `64` | Invalid arguments (`EX_USAGE`).                                | ArgumentParser |

All codes outside this table are bugs; please report them.

### Dispatching on exit code

```sh
output=$(roar send --wait \
    --title "Deploy?" \
    --body "Push v3.2.0 to production?" \
    --action ok:Approve --action no:Reject)
case $? in
    0) action=$(printf '%s' "$output" | head -n1)  # see --wait stdout below
       ;;
    2) echo "no answer in time" ;;
    3) echo "user dismissed" ;;
    *) echo "unexpected exit" ;;
esac
```

In `--wait`, exit `0` covers **both** the default-click and any
custom-action click — distinguishing those needs stdout. Exit `3`
covers the explicit-dismiss case alone, and exit `2` the timeout.

## The `--wait` stdout protocol

When `--wait` is set, Roar blocks until one of: user interaction,
the `--wait-timeout` window elapses, or the process is signalled.
On normal completion it prints **exactly** the following bytes:

### Default click (banner body itself)

```
default\n
```

Exit code `0`.

### Custom action button

```
<action-id>\n
```

Where `<action-id>` is the literal id from `--action id:Title`. Exit
code `0`. Custom ids are screened at parse time to contain no
whitespace, newlines, or control characters — what you receive is
exactly what you typed.

### Reply-style text action

```
<action-id>\n
<typed text>\n
```

Where `<action-id>` is the `--text-action`'s id and `<typed text>`
is the user's reply **verbatim**. The reply can contain:

- Embedded newlines (the user pressed return mid-message)
- NUL bytes (paranoid input)
- Arbitrary UTF-8

So: **read the trailing payload until EOF, not line-by-line.** A
naive `head -n 2` would truncate at the first newline in the typed
text. Exit code `0`.

### Explicit dismiss

```
dismiss\n
```

Exit code `3`. macOS's reverse-DNS
`UNNotificationDismissActionIdentifier` is collapsed to the short
sentinel before printing so your scripts don't have to track Apple's
naming.

### Timeout

```
timeout\n
```

Exit code `2`. No `--wait-timeout` flag → 5-minute default.

### Reserved sentinel ids

`default` and `dismiss` are **reserved** — Roar rejects them at
parse time so custom-action stdout can't collide with the
default-click and explicit-dismiss sentinels:

```
--action id 'default' is reserved (it's used to signal the default
click / explicit dismissal in --wait mode). Choose a different id.
```

`timeout` is **not** currently rejected, but you should still
avoid it as an action id: a `--action timeout:...` click prints
`timeout\n` on stdout with exit code 0, while a `--wait-timeout`
expiry prints the same `timeout\n` with exit code 2. Branching on
stdout alone can't tell them apart — your shell `case` arm has to
check `$?` too.

Treat the three labels — `default`, `dismiss`, `timeout` — as
sentinels you never reuse as user ids.

## Shell patterns

### Capture an action id, branch on it

```sh
choice=$(roar send --wait \
    --title "Deploy" \
    --action approve:Approve \
    --action reject:Reject::destructive)
ec=$?
case "$ec::$choice" in
    0::approve) ./deploy.sh ;;
    0::reject)  echo "rejected by user" ;;
    2::*)       echo "no answer in time" ;;
    3::*)       echo "user dismissed" ;;
esac
```

Branch on `$ec::$choice` (not `$choice` alone) so the timeout
(exit 2, stdout `timeout`) and explicit-dismiss (exit 3, stdout
`dismiss`) cases are caught even if a user-defined action shares
one of those ids.

### Branch on stdout AND exit code

```sh
output=$(roar send --wait \
    --title "Quick log entry" \
    --text-action save:Save \
    --text-placeholder "what did you do today?")
ec=$?
case $ec in
    0)
        action=$(printf '%s' "$output" | head -n1)
        text=$(  printf '%s' "$output" | tail -n+2)
        printf '%s\n' "$text" >> ~/journal.md
        ;;
    2) echo "no entry today" ;;
    3) echo "cancelled" ;;
    *) echo "error (ec=$ec)"; exit "$ec" ;;
esac
```

### Read multi-line replies safely

```sh
# Read the action id from the first line, then everything else as the
# message — preserving embedded newlines.
roar send --wait --text-action reply:Send | {
    IFS= read -r action
    text=$(cat)
    printf 'action=%s\n' "$action"
    printf 'text=<<EOF\n%sEOF\n' "$text"
}
```

### Race a `--wait` against another event

`--wait` blocks the entire process. To race it against e.g. a
deploy completing externally, use a background process:

```sh
{ roar send --wait --title "Approve?" --body "..." --action ok:Approve > /tmp/choice.txt; \
  echo $? > /tmp/choice.exit; } &
wait_pid=$!

while kill -0 "$wait_pid" 2>/dev/null; do
    if [[ -f /tmp/deploy.done ]]; then
        kill "$wait_pid"   # send SIGTERM; exit code on signalled
                           # death is shell-defined (~128+signum),
                           # outside Roar's documented set — don't
                           # branch on it
        break
    fi
    sleep 1
done
```

## Python integration

```python
import subprocess
import sys

result = subprocess.run(
    [
        "roar", "send", "--wait",
        "--title", "Deploy?",
        "--action", "ok:Approve",
        "--action", "no:Reject",
        "--wait-timeout", "1m",
    ],
    capture_output=True,
    text=True,
)

# Tail the protocol carefully.
match result.returncode:
    case 0:
        # action_id is everything before the first newline; remaining
        # bytes (if any) are the text-action reply.
        action_id, _, reply = result.stdout.partition("\n")
        if action_id == "ok":
            ...
        elif action_id == "no":
            ...
        elif action_id == "default":
            # User clicked the body, not a button.
            ...
    case 2:
        print("user did not respond in time")
    case 3:
        print("user dismissed the notification")
    case 4:
        # Not reachable for `send`, but documented here as a reminder
        # that `roar dismiss` uses code 4 for the "no match" case.
        ...
    case 64:
        # ArgumentParser rejected the invocation — the stderr buffer
        # has the diagnostic.
        print("usage error:", result.stderr, file=sys.stderr)
```

## CI integration

### Don't block on a permission dialog

Roar requests *provisional* authorization on first run. macOS grants
this silently, so a fresh CI runner won't wedge on a modal. The
trade-off is that notifications post quietly to Notification Center
(no banner / sound) until the user promotes the app —
acceptable for an unattended runner.

If your CI workflow includes an interactive approval gate via
`--wait`, configure a sensible timeout:

```yaml
- name: Manual approval
  shell: bash
  run: |
    set -o pipefail
    choice=$(roar send --wait --wait-timeout 5m \
        --title "Approve release v${{ env.VERSION }}?" \
        --action ok:Approve --action no:Reject)
    ec=$?
    case $ec in
        0)
            if [[ "$choice" == "ok" ]]; then
                echo "approved=true" >> "$GITHUB_OUTPUT"
            else
                echo "approved=false" >> "$GITHUB_OUTPUT"
            fi
            ;;
        2) echo "approved=timeout" >> "$GITHUB_OUTPUT" ; exit 1 ;;
        3) echo "approved=dismiss" >> "$GITHUB_OUTPUT" ; exit 1 ;;
        *) exit "$ec" ;;
    esac
```

### Suppressing notifications in CI

You can't conditionally compile Roar out — but you can wrap it with a
guard:

```sh
roar_send() {
    [[ "${CI:-}" = "true" ]] && return 0
    roar send "$@"
}

roar_send --body "Build finished"
```

## Pitfalls

### Don't parse stderr

stderr carries diagnostics that may include user-typed flag values,
URLs, and arbitrary strings. The format is human-oriented and not
contractual. Parse exit codes and stdout instead.

### Don't depend on the order of action ids in `--help`

The `--help` output renders flags in the order they're declared. New
flags may be added between existing ones. If you script around
`roar send --help`, match by flag name, not position.

### `--wait` keeps the process alive

A `roar send --wait` that's never clicked will run for the entire
`--wait-timeout` window (default 5 minutes). Don't background-spawn
hundreds of them — each holds an AppKit runloop and an XPC
connection to `usernoted`. Use scheduled triggers (`--in` / `--at`)
for fire-and-forget cases.

### `--identifier` is the only path to in-place updates

Roar mints a fresh UUID for every send by default. To update a
banner instead of stacking a new one, you must pass `--identifier`
with the same value on subsequent sends.

### Identifier length cap

Roar caps identifiers (and `--thread-id`, `--target-content-id`,
`--filter-criteria`) at 256 characters; longer values are
rejected at validation time. Rationale and the underlying
framework behaviour are in
[Security → identifier length cap](SECURITY.md#12-identifier-length-cap).

### `--at` is local time unless you specify a zone

`2026-12-31 17:00:00` is interpreted in the **system's** timezone at
parse time. If you share a script across timezones, prefer the ISO
8601 zoned form (`...Z` or `...+01:00`).

### Identifier collisions across `roar send` invocations

Two `roar send --identifier build` calls from different shells run
in a last-writer-wins race. The XPC bridge to `usernoted`
serialises individual requests in arrival order, so the second send
replaces the first. There's no locking primitive — if you depend on
serialisation, sequence the calls upstream.

## A few worked examples

### "Touch this banner to ack the page"

```sh
output=$(roar send --wait \
    --title "Pager: $alert" \
    --body "$details" \
    --action ack:Ack \
    --interruption-level time-sensitive \
    --wait-timeout 15m)
case $? in
    0) [[ "$output" == "ack" ]] && curl -X POST "$PAGER_ACK_URL" ;;
    2|3)
        # No ack — escalate.
        curl -X POST "$ESCALATE_URL"
        ;;
esac
```

### "Replace-in-place progress"

```sh
roar send --identifier dl --body "Downloading: queued"

while read -r progress; do
    roar send --identifier dl --body "Downloading: $progress"
done < <(curl -fsSL https://api.example.com/progress | jq -r '.percent')

roar send --identifier dl --body "Download complete"
```

### "Confirm before destructive op"

```sh
if [[ "$choice" != "yes" ]]; then
    choice=$(roar send --wait \
        --title "Confirm: rm -rf /opt/foo" \
        --body "This will delete $files files. Proceed?" \
        --action yes:Delete::destructive \
        --action no:Cancel \
        --wait-timeout 30s)
    case "$choice"::$? in
        yes::0)   rm -rf /opt/foo ;;
        no::0)    echo "cancelled" ;;
        *::2)     echo "timed out, refusing to proceed" ; exit 1 ;;
        *::3)     echo "dismissed, refusing to proceed" ; exit 1 ;;
    esac
fi
```

## See also

- [`COOKBOOK.md`](COOKBOOK.md) — task-oriented recipes.
- [`SECURITY.md`](SECURITY.md) — the threat model that motivates the
  validation / consent flags.
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — diagnosing notification
  delivery and click-handler issues.
- `man roar` — the full reference page.
