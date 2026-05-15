# `roar list`

Print delivered + pending notifications as tab-separated values
(TSV). One row per notification.

## Flags

| Flag | Effect |
|---|---|
| `--delivered` | Show only delivered notifications. |
| `--pending` | Show only pending (scheduled, not yet fired) requests. |
| `--header` | Emit a TSV header row before the data. |

Default (no flags): both buckets, no header.

## Output format

Five tab-separated columns, in this order. With `--header`, the
first row is the literal header line `ID\tSTATUS\tTIME\tTITLE\tBODY`.

| # | Column | Contents |
|---|---|---|
| 1 | `ID` | `UNNotificationRequest.identifier` — the value you passed via `--identifier`, or the UUID Roar minted. |
| 2 | `STATUS` | `delivered` or `pending`. |
| 3 | `TIME` | ISO 8601 UTC. For delivered, the delivery time; for pending, the next fire date returned by `nextTriggerDate()`. Triggers that report no next date emit the literal string `(unscheduled)`. |
| 4 | `TITLE` | Notification title. Tabs / newlines / other control characters are flattened to single spaces so each row stays on one line. |
| 5 | `BODY` | Notification body, same single-line flattening. |

The format is stable for scripting — treat it as an ABI.

```sh
roar list
roar list --pending --header
```

To act on identifiers, pipe to `awk` or `cut`. The ID is column 1:

```sh
roar list --delivered | awk -F'\t' '{print $1}' | xargs roar dismiss
```
