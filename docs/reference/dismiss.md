# `roar dismiss`

Remove one or more notifications by identifier. Targets both
delivered and pending in a single call.

## Arguments

`roar dismiss <id> [<id>...]` — one or more identifiers. Same
validation as `--identifier` on `send` (non-empty, no control
chars, 256-char cap).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | At least one identifier matched and was dismissed. |
| 4 | No identifier matched any delivered or pending notification (`noMatchExitCode`). Distinct from 0 so scripts can branch on `$?` rather than parsing stderr. |
| 64 | `EX_USAGE` — empty identifier list or other ArgumentParser rejection. |

Unknown identifiers are reported on stderr by name; the dismiss
of every other id still happens.

```sh
roar dismiss build-status
roar dismiss build-status deploy-status   # multiple
```
