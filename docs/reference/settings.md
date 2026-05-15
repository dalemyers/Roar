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
