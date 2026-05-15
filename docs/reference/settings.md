# `roar settings`

Print the current OS-level notification settings for `roar` as
plain `key: value` lines. No flags.

Useful as a diagnostic — see
[Troubleshooting → quick diagnostic checklist](../TROUBLESHOOTING.md#quick-diagnostic-checklist).

Output keys (rendered in this order):

| Key | Type / values |
|---|---|
| `authorization-status` | `not-determined` / `denied` / `authorized` / `provisional` / `ephemeral` / `unknown` |
| `alert-setting` | `enabled` / `disabled` / `not-supported` / `unknown` |
| `alert-style` | `none` / `banner` / `alert` / `unknown` |
| `sound-setting` | `enabled` / `disabled` / `not-supported` / `unknown` |
| `lock-screen-setting` | `enabled` / `disabled` / `not-supported` / `unknown` |
| `notification-center-setting` | `enabled` / `disabled` / `not-supported` / `unknown` |
| `critical-alert-setting` | `enabled` / `disabled` / `not-supported` / `unknown` |
| `show-previews-setting` | `always` / `when-authenticated` / `never` / `unknown` |
| `time-sensitive-setting` | `enabled` / `disabled` / `not-supported` / `unknown` |
| `scheduled-delivery-setting` | `enabled` / `disabled` / `not-supported` / `unknown` |
| `direct-messages-setting` | `enabled` / `disabled` / `not-supported` / `unknown` (macOS 14+; `not-supported` on macOS 13) |
| `provides-app-notification-settings` | `true` / `false` |

All `-setting` keys map to `UNNotificationSetting`: `not-supported`
means the OS reports the affordance as unavailable on this
platform (e.g. `critical-alert-setting` for a CLI without the
Apple-granted entitlement); `disabled` means the user has turned
it off; `enabled` means it's on.

```sh
roar settings
roar settings | grep '^authorization-status'
```

## JSON output (`--json`)

Pass `--json` to emit a JSON object instead of `key: value` lines.
Keys match the text format's spelling exactly (dashed, not
camelCased) so consumers can mechanically map between the two
representations.

```json
{
  "authorization-status": "authorized",
  "alert-setting": "enabled",
  "alert-style": "banner",
  "sound-setting": "enabled",
  "lock-screen-setting": "enabled",
  "notification-center-setting": "enabled",
  "critical-alert-setting": "not-supported",
  "show-previews-setting": "always",
  "time-sensitive-setting": "enabled",
  "scheduled-delivery-setting": "disabled",
  "direct-messages-setting": "not-supported",
  "provides-app-notification-settings": false
}
```

Every key in the table above appears in the JSON output. Values
use the same token vocabulary (`enabled` / `disabled` /
`not-supported` / etc.); the only value-shape difference from
the text format is `provides-app-notification-settings`, which
is a real JSON boolean rather than the literal string `true` /
`false`.

```sh
# Is Roar authorized at all?
roar settings --json | jq -r '."authorization-status"'

# Are time-sensitive notifications enabled?
roar settings --json | jq -r '."time-sensitive-setting"'
```
