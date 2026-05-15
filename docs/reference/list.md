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

## JSON output (`--json`)

Pass `--json` to emit a JSON array instead of TSV. One object per
notification:

```json
[
  {
    "bucket": "delivered",
    "when": "2026-05-15T13:00:00Z",
    "identifier": "build-status",
    "title": "Build complete",
    "body": "All green"
  },
  {
    "bucket": "pending",
    "when": null,
    "identifier": "weekly-standup",
    "title": "Standup",
    "body": "9am Mondays"
  }
]
```

| Field | Type | Notes |
|---|---|---|
| `bucket` | `"delivered"` \| `"pending"` | Mirrors the TSV `STATUS` column. |
| `when` | `string` (ISO 8601 UTC) \| `null` | Delivery time for delivered, next-fire date for pending. `null` replaces the TSV `(unscheduled)` sentinel when the framework can't resolve a next-fire date. |
| `identifier` | `string` | The `UNNotificationRequest.identifier`. |
| `title` | `string` | Notification title, emitted verbatim. Newlines and control characters survive (JSON string escaping handles them); no `flatten()` is applied. |
| `body` | `string` | Notification body, same verbatim treatment. |

The schema is stable scripting ABI — fields may be added, but
renames or removals are major-version breaks. `null` always
appears explicitly for unresolved `when` rather than being
omitted, so `jq '.when'` returns a value (string or null) every
time.

```sh
# All delivered titles
roar list --delivered --json | jq -r '.[].title'

# Identifiers of every pending notification
roar list --pending --json | jq -r '.[].identifier'
```

`--header` is ignored under `--json` — JSON object keys are
self-describing.
