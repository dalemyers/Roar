# `roar clear`

Bulk-remove notifications by scope. Safer than `dismiss` for
"wipe the slate" because scope is explicit.

## Flags

| Flag | Effect |
|---|---|
| (none) | Clear only the delivered bucket. Pending requests preserved. |
| `--delivered` | Same as default. Kept for explicitness. |
| `--pending` | Clear only the pending bucket. |
| `--all` | Clear both buckets. |
| `--categories` | Additionally prune `roar.dyn.*` notification categories no longer referenced by any delivered or pending notification. Combine with a scope flag, or pass alone to prune without clearing notifications. |

`--delivered`, `--pending`, and `--all` are mutually exclusive.

The "delivered-only by default" choice is deliberate: a typo'd
`roar clear` shouldn't destroy scheduled work — see
[Security → clear scope default](../SECURITY.md#14-roar-clear-safer-default).

```sh
roar clear                       # delivered only
roar clear --all                 # both buckets
roar clear --all --categories    # both buckets + prune unreferenced categories
roar clear --categories          # just the prune, leave notifications alone
```

## JSON output (`--json`)

Pass `--json` to emit a JSON summary of which scopes the
invocation cleared. The text path is silent; the JSON path gives
a downstream observer a structured confirmation.

```json
{
  "delivered_cleared": true,
  "pending_cleared": false,
  "categories_pruned": false
}
```

| Field | Type | Notes |
|---|---|---|
| `delivered_cleared` | boolean | `true` when the invocation cleared the delivered bucket (default, or `--delivered`, or `--all`). |
| `pending_cleared` | boolean | `true` when the invocation cleared the pending bucket (`--pending` or `--all`). |
| `categories_pruned` | boolean | `true` when `--categories` was passed. |

The booleans are scope-flags, not counts — UN's `removeAll*`
APIs are fire-and-forget and don't surface a "removed N
notifications" number. If you need a count, snapshot
`roar list --json | jq 'length'` before and after.

```sh
# Confirm a scheduled-only clear didn't touch delivered
roar clear --pending --json | jq -e '.pending_cleared and (.delivered_cleared | not)'
```
