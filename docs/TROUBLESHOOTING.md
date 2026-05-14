# Troubleshooting

If `roar send` exits cleanly but you don't see a notification — or
the click handler "does nothing," or the schedule never fires — the
fix is almost always at the OS layer (System Settings, Focus rules,
provisional auth), not in Roar. This guide walks through the
common symptoms.

## "I ran `roar send` and nothing happened"

The most common cause is **provisional authorization**: the first
time Roar runs, macOS grants it provisional auth silently. The
trade-off is that notifications post quietly to Notification Center
— no banner, no sound, no badge break-through.

Diagnose:

```sh
roar settings
```

If the output includes `authorization-status: provisional`,
notifications **are** being delivered, just quietly. Open
Notification Center (click the clock at the top-right, or
swipe-from-the-right) and you'll see them.

To promote to full authorization:

- Tap **Keep** on the next notification Roar delivers, **or**
- System Settings → Notifications → Roar → toggle **Allow
  Notifications** on, then choose Banner or Alert.

After promotion, `roar settings` reports
`authorization-status: authorized` and subsequent sends have
banner+sound+badge affordances.

## "`authorization-status: denied`"

You (or somebody) said No to the notification permission dialog.
Re-enable it:

1. System Settings → Notifications.
2. Scroll to **Roar**.
3. Toggle **Allow Notifications** on.
4. Choose **Banner** or **Alert**, set sound preferences.

Roar exits with code `1` and prints to stderr in this state, so
scripts can branch on it.

## "I get `authorization-status: notDetermined` every run"

Roar requests authorization on every cold start. If you keep seeing
`notDetermined`, the request is failing — usually because the
bundle id isn't registered with LaunchServices:

```sh
lsregister -f /Applications/roar.app
```

`lsregister` lives in
`/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister`,
so add it to your `PATH` or use the full path:

```sh
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f /Applications/roar.app
```

If Roar is run from somewhere other than `/Applications`, every
relaunch will potentially re-register and confuse the permission
record. Install the `.app` into `/Applications` and `ln -s` the
binary onto your `PATH`.

## "I see the notification but it doesn't play a sound"

Check the cause in order:

1. **Did you pass `--sound`?** Roar doesn't play a sound by default.
   ```sh
   roar send --body "Test" --sound Glass
   ```
2. **Provisional auth?** `roar settings` → `authorization-status:
   provisional`. Provisional mode silently strips sound; promote
   (see above).
3. **Focus mode?** Open Control Center, check the Focus toggle.
   Time-sensitive sends bypass it; passive/active do not.
4. **Sound name typo?** `UNNotificationSound(named:)` falls back
   silently to no sound. Roar's `--sound` validator probes
   `/System/Library/Sounds` and `/Library/Sounds` for an `.aiff`
   or `.caf` file with that name; unknown names are rejected. Use
   `default` for the default notification sound:
   ```sh
   roar send --body "Test" --sound default
   ```
5. **Custom sound file?** macOS only resolves sounds by name from
   system directories. `~/Library/Sounds/Foo.aiff` exists on disk
   but the framework won't find it. Use `--sound default`, install
   the sound to `/Library/Sounds`, or pre-play with `afplay` via
   `--exec`.

## "`--interruption-level time-sensitive` doesn't break through Focus"

Roar can request a time-sensitive interruption level, but the user
has to permit it in Focus configuration:

1. System Settings → Focus → (the active Focus).
2. **Allowed Notifications** → **Apps**.
3. Add Roar, then toggle **Time Sensitive Notifications** on for
   Roar within that Focus.

Without that, `time-sensitive` gets demoted to active and respects
the Focus mute rules like any normal notification.

The `.critical` level is gated behind an Apple-granted entitlement
(`com.apple.developer.usernotifications.time-sensitive`); an ad-hoc-
signed CLI cannot claim it. There's no flag for it.

## "My badge doesn't update"

`UNMutableNotificationContent.badge` updates the dock icon's badge,
but Roar runs with `LSUIElement: true` and **does not appear in the
Dock**. The badge number is still recorded; it'll show up if your
notification gets summarised in Notification Center, but you won't
see a Dock badge — Roar deliberately has no Dock presence.

For a visible badge counter, post the notification under another
app's bundle id via a different tool, or assign Roar a Dock icon by
removing `LSUIElement: true` from `project.yml` and rebuilding.

## "My `--at` schedule fired immediately"

Most likely the timestamp is in the past. Roar rejects past
timestamps at parse time, but only if the year/month/day are
absolute. Common gotchas:

- **Wrong year.** `--at "2024-12-31"` in 2026 is past. Roar prints:
  ```
  --at '2024-12-31' is in the past. macOS would fire it immediately,
  which contradicts the 'scheduled' intent; use a future timestamp
  or omit --at for immediate delivery.
  ```
- **Local-time confusion.** `--at "2026-12-31 09:00"` is interpreted
  in the **system's** timezone at parse time. If you copy-paste a
  UTC timestamp into the local-time form, the schedule fires
  earlier or later than you expect. Use the ISO 8601 form
  (`...Z` or `...+01:00`) to be explicit.
- **Less than 1 second in the future.** Roar's minimum schedule
  interval is 1s. Anything closer is rejected:
  ```
  --at '...' is too close to now (0.5s away); must be at least
  1.0s in the future.
  ```

## "My `--in` value was rejected"

Grammar is strict: `<number><unit>` where unit is `s` / `m` / `h` /
`d`. Floats are allowed (`1.5h`). Rejected shapes:

- Hex floats (`0x1p3s`)
- Scientific notation (`1e10s`)
- Signed (`+30s`)
- NaN / Inf literals
- Bare numbers (`30`)

Min 1s, max 365d. The error message says exactly which constraint
fired.

## "`--repeat monthly:31:..` doesn't fire some months"

macOS silently skips months without that day-of-month — February,
April, June, September, November don't have a 31st. The recurring
trigger uses the framework's `UNCalendarNotificationTrigger`, which
matches "the 31st of every month" against the calendar's actual
day-of-month field. There's no "last day of month" semantics
exposed; if you need that, schedule separate `daily:HH:MM` runs
or post once per month from cron.

## "My `--attachment` was rejected"

Roar accepts **local paths only**. Common rejections:

- `http://...` or `https://...` — pre-download with
  `curl -fsSL -o /tmp/foo URL` and pass the local path.
- `file://hostname/...` — use `file:///...` (three slashes,
  empty host).
- `~user/foo` — `~` only expands the current user. Use an absolute
  path or `~/foo`.
- **Path is a symlink.** Roar refuses leaf symlinks because the
  target may differ from what you typed. Pass the real path:
  ```sh
  ls -l /path/that/looks/normal
  # if it's a symlink: lrwxr-xr-x ... /path/... -> /actual/target
  roar send --attachment /actual/target
  ```
- **Intermediate symlink not on the allow-list.** Only `/tmp`,
  `/var`, `/etc` (the macOS system symlinks) are accepted as
  intermediates. A custom `/Users/me/cache -> /Volumes/EXT/cache`
  symlink will refuse — make the path use the volume's real mount
  point.
- **Not a regular file.** Directories, FIFOs, sockets, and devices
  are rejected with the file-type bits in the diagnostic.

See [SECURITY.md](SECURITY.md) for the threat model.

## "`--open-url 'vscode://...'` was rejected"

Only `http`, `https`, `mailto` are accepted by default. Custom
schemes must be opted in **one at a time** with `--allow-url-scheme`:

```sh
roar send --open-url "vscode://file/foo" --allow-url-scheme vscode
```

For multiple schemes, repeat the flag:

```sh
roar send --open-url "tel:+1234567890" \
    --allow-url-scheme tel \
    --allow-url-scheme sms
```

There is deliberately **no global "accept anything" flag**. The
allow-list is a default-deny posture: by default `--open-url`
rejects any scheme outside http / https / mailto, which is what
catches the case where a script passes `--open-url "$URL"` and
`$URL` turned out to be `javascript:...`. Without the allow-list,
that would silently post a notification whose click runs JS. With
it, the send is rejected at parse time and no notification is
created. The pinned allow-list is also re-validated at click time
against the userInfo blob, so a click later — possibly in a
different process — can't open a scheme the send didn't agree to.

For the full rationale (and the cases the allow-list does NOT
defend against, like a same-bundle-id spoofer or a hostile https
destination), see [SECURITY.md](SECURITY.md).

## "`--exec` was rejected"

Two common causes:

- **Missing `--allow-shell-on-click`.** `--exec` is consent-gated.
  Re-run with both flags:
  ```sh
  roar send --body "Click me" --exec "echo hi" --allow-shell-on-click
  ```
- **NUL byte in the command.** `posix_spawn`'s `strdup` truncates
  at NUL, so a command containing `\0` would silently change. Roar
  rejects up front.

## "`--wait` hangs forever"

It doesn't, but it can sit for up to 5 minutes by default. The
`--wait-timeout` is 5m unless you override:

```sh
roar send --wait --body "Test" --wait-timeout 30s
```

The minimum is 1s; the maximum is 365d (same bounds as `--in`).
If you genuinely want forever, pass `365d`.

## "`roar dismiss <id>` exits 4"

That's the documented exit code for "no id matched any delivered
or pending notification." Either:

- The id you typed is misspelled. Run `roar list` to see what
  Roar knows about.
- The notification was already dismissed by another process.
- The notification was posted by another app under a different
  bundle id — Roar only sees notifications under `io.myers.roar`.

## "`roar list` shows nothing"

Each app sees only its own notifications. `roar list` lists
notifications posted under `io.myers.roar`. To see all OS-level
notifications, use Notification Center (click the clock).

## "`roar clear` didn't clear scheduled notifications"

Bare `roar clear` clears only delivered notifications. Use
`--all` for both buckets:

```sh
roar clear --all
```

This is the safe default — a typo'd `roar clear` from the shell
prompt no longer destroys upcoming scheduled work.

## "I see categories accumulating in some inspection tool"

Every `roar send` with `--action`/`--text-action` registers a
`roar.dyn.<hash>` category. They never expire; the set grows
monotonically. Prune them:

```sh
roar clear --categories                # prune unused
roar clear --all --categories          # clear notifications, then prune
```

The pruner only drops `roar.dyn.*` categories that aren't
referenced by a currently-delivered or pending notification. It's
idempotent and uses a double-snapshot protocol so a concurrent
`roar send` doesn't get clobbered.

## "Notifications stay in NC forever"

That's the OS's behaviour, not Roar's. To clear:

```sh
roar clear                # delivered only
roar clear --all          # delivered + pending
```

Or use Notification Center's "Clear" affordance directly.

## Debugging the click handler

The click handler runs **out-of-process** from your shell — when you
click a banner, macOS spawns Roar's bundle to receive the click
delivery. By default Roar is silent in the click path so URLs and
shell commands don't leak into the unified log under launchd.

Enable verbose stderr logging with `ROAR_DEBUG`:

```sh
ROAR_DEBUG=1 roar send --body "Click me" --open-url https://example.com
# Click the banner. Diagnostics now print to stderr in the
# click-handler process. Find them with:
log stream --predicate 'process == "roar"' --info --debug
```

The `ROAR_DEBUG` env var is read fresh on every diagnostic write —
no caching — so you can flip it on/off across runs without
restarting anything.

For send-time errors, `ROAR_DEBUG` is unnecessary: those go to the
shell's stderr directly. Increased verbosity is mostly useful for
the click handler.

## Reading the unified log

When the click handler does something noteworthy, the trace lands
in the unified log:

```sh
# Live tail:
log stream --predicate 'process == "roar"' --info

# Last 5 minutes:
log show --predicate 'process == "roar"' --info --last 5m
```

`usernoted` (the system notification daemon) logs sends and
deliveries:

```sh
log stream --predicate 'process == "usernoted"' --info
```

## Reset Roar's notification state

If you've gotten the permission record into a weird state:

```sh
# Drop all cached defaults for Roar.
defaults delete io.myers.roar 2>/dev/null

# Bounce usernoted (launchd respawns it immediately).
killall usernoted

# Re-register the bundle.
lsregister -f /Applications/roar.app
```

Then run `roar send --body "test"` and walk through the first-run
permission flow again.

## Quick diagnostic checklist

When in doubt, paste this output into an issue:

```sh
echo "=== roar --version ==="
roar --version
echo
echo "=== roar settings ==="
roar settings
echo
echo "=== auth & focus ==="
defaults read com.apple.controlcenter 2>/dev/null | grep -i focus
echo
echo "=== lsregister ==="
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -dump 2>/dev/null | grep -A2 -i roar | head -20
echo
echo "=== recent usernoted entries ==="
log show --predicate 'process == "usernoted" OR process == "roar"' \
    --info --last 5m 2>/dev/null | head -50
```

The first three give the OS state; the last surfaces any errors
from the recent send / click attempts.

## See also

- [`COOKBOOK.md`](COOKBOOK.md) — task-oriented recipes.
- [`SCRIPTING.md`](SCRIPTING.md) — `--wait` protocol and exit codes.
- [`SECURITY.md`](SECURITY.md) — the threat model that motivates
  the consent gates.
- `man roar` — the full reference.
