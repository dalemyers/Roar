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
