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

## JSON output (`--json`)

Pass `--json` to emit a JSON summary on stdout instead of the
text path's silent-stdout / warnings-on-stderr shape.

```json
{
  "requested": ["build-status", "deploy-status", "build-status"],
  "unknown": ["deploy-status"]
}
```

| Field | Type | Notes |
|---|---|---|
| `requested` | array of strings | The argv as the user typed it, in order, **including duplicates**. |
| `unknown` | array of strings | Deduplicated subset that didn't match any delivered or pending notification. Same data the text path emits to stderr. |

Exit codes are unchanged: 0 if at least one distinct identifier
matched, `noMatchExitCode` (4) if none did, 64 on usage errors.
JSON-mode invocations don't emit anything on stderr — the
`unknown` array IS the diagnostic.

```sh
# How many of my requested ids actually existed?
total=$(roar dismiss --json a b c | jq '.requested | length')
unknown=$(roar dismiss --json a b c | jq '.unknown | length')
echo "$((total - unknown)) dismissed, $unknown unknown"
```
