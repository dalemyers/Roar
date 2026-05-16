# Concepts

How macOS notifications actually work, and where Roar sits in
that stack. Reading this first makes the rest of the docs make
sense; most of the flag-by-flag details in [Reference](reference/index.md)
hang off the concepts here.

## The macOS notification stack

```
   roar send …
        │
        ▼  XPC
   ┌──────────┐                         ┌────────────────────┐
   │ usernoted │  delivery + click  ──▶ │ Notification Center│
   │  (daemon) │                         └────────────────────┘
   └────────┬─┘
            │
            ▼  on click: relaunch the bundle
   /Applications/Roar.app  ── handles click → exits
```

- **`UNUserNotificationCenter`** — the framework API in Roar's
  Swift code. Roar uses it to request authorization, build
  notification content, register categories, and submit
  requests (`center.add(_:)`).
- **`usernoted`** — the per-user daemon every notification
  flows through. It owns the on-disk state (delivered list,
  pending requests, registered categories), the banner UI, and
  the click dispatch. Bouncing it (`killall usernoted`) is the
  blast-radius fix for "weird icon" / "stale category" /
  "stuck-in-NC" classes of issue.
- **Notification Center** — the UI surface (the slide-in
  panel from the top-right corner). It's a view onto
  `usernoted`'s state, not its own storage.

Roar sits at the top of the diagram: it builds a notification
request and sends it to `usernoted` via the framework's XPC
bridge. Once that ack returns (typically within ~100 ms), Roar
exits. Everything downstream — delivery timing, banner styling,
click routing — happens inside `usernoted` and the framework.

## The bundle-with-a-CLI shape

Roar is distributed as **`Roar.app`** (a notarised, signed
`LSUIElement: true` AppKit bundle). The `roar` command users
invoke from the shell is a symlink onto the inner executable at
`Contents/MacOS/roar`.

The wrapping is required by macOS, not chosen:

1. **`UNUserNotificationCenter` refuses to operate** from a
   binary that isn't part of an app bundle. The framework
   reads `Bundle.main.bundleIdentifier` to scope auth grants,
   notification settings, and on-disk state; without a
   bundle, none of that machinery has a place to anchor.
2. **Click handlers re-launch the bundle.** When the user
   clicks a delivered notification, macOS launches
   `Roar.app` via LaunchServices, passing the notification's
   `UNNotificationResponse` through the
   `UNUserNotificationCenterDelegate`. Without a bundle there's
   nothing for LaunchServices to launch.
3. **Notarisation gates on .app bundles**, not bare binaries.
   Apple's notary service is what makes the downloaded artifact
   pass Gatekeeper without per-machine fiddling.

`LSUIElement: true` is what keeps the bundle from showing in
the Dock or the Cmd-Tab switcher — `roar` behaves like a normal
CLI even though it's structurally an app.

## Authorization

Every macOS app that posts notifications needs the user's
permission. Roar requests **provisional** authorization on the
first send.

### Provisional vs full authorization

- **Provisional**: granted *silently*, no permission dialog.
  Notifications post quietly to Notification Center — no
  banner, no sound. Useful for unattended invocations (cron /
  launchd / CI) that shouldn't block on a modal dialog. Roar's
  first-run experience uses this.
- **Full**: the user has explicitly accepted notifications,
  either by tapping **Keep** on a provisional notification or
  by flipping the switch in **System Settings → Notifications →
  Roar**. Banners and sounds work normally.

`roar settings` shows the current state under
`authorization-status: <value>` — see
[Reference → roar settings](reference/settings.md) for the full
value set.

Going from provisional → full is a one-time user action. Once
flipped it survives reboots. There's no programmatic upgrade
path — by design; macOS reserves the right to gate this on a
real user interaction.

### What you can request, what you can't

Roar asks for `[.alert, .sound, .provisional]`. Two adjacent
options are deliberately **not** requested, and the reasons are
worth knowing:

- **`.timeSensitive`** is deprecated as an authorization option
  in macOS 12+; the entitlement
  `com.apple.developer.usernotifications.time-sensitive` is now
  the gating mechanism, and an ad-hoc-signed CLI can't claim
  it. `--interruption-level time-sensitive` still flows
  through, but its actual break-through behaviour depends on
  the user's Focus configuration, not on Roar's auth grant.
- **`.critical`** requires Apple-approved entitlement (per-
  developer); not available to an unentitled bundle. Roar
  deliberately doesn't expose `--interruption-level critical`.

## Identifiers, threads, categories

Three distinct identifiers each play a role, and they're easy to
confuse for first-time users.

### Request identifier (`--identifier`)

The handle for **one specific notification**.
`UNNotificationRequest.identifier`. Reposting with the same
identifier *replaces* the prior notification in place — no
flicker, no duplicate, no second sound. Omit it to mint a
fresh UUID per send.

When you'd set it: build status, in-flight progress, status
pings, anything that should update rather than accumulate.

When you'd omit it: independent posts that should each live
their own NC lifetime (e.g. "a new PR was opened").

### Thread identifier (`--thread-id`)

The handle for **a group of related notifications**.
`UNMutableNotificationContent.threadIdentifier`. macOS stacks
notifications with the same thread into a single visual group
in Notification Center.

A pair of notifications can share `--thread-id` without
sharing `--identifier`: the thread is the collapsible UI
grouping, the identifier is the per-message handle.

When you'd set it: build pipelines posting multiple events,
chat-message-style streams, batches of related alerts.

### Category identifier (Roar-managed)

The handle for **the set of actions / metadata** attached to a
notification: which custom buttons appear, what the lock-
screen privacy options are, the summary format string.
Categories are registered with `UNUserNotificationCenter.setNotificationCategories(_:)`
and referenced from each request by
`UNMutableNotificationContent.categoryIdentifier`.

Roar mints a category identifier of the form `roar.dyn.<hash>`
where the hash is over `(actions + display options +
hidden-previews settings + summary format)`. The same
configuration always produces the same id — so unrelated
sends with identical action sets share a category.

You don't set this directly. `--action`, `--text-action`,
`--hide-previews-body-placeholder`, `--summary-format`, and
the `--show-*-when-previews-hidden` flags all feed into the
hash.

Categories accumulate over time (UN doesn't garbage-collect
them on its own). `roar clear --categories` prunes any
`roar.dyn.*` entry not referenced by a currently delivered or
pending notification.

## Foreground vs background delivery

A notification has two distinct delivery contexts:

- **Background delivery**: Roar has already exited by the
  time `usernoted` delivers the notification. This is the
  common case — for non-`--wait` sends, Roar exits ~100 ms
  after `add(_:)` returns. The system's default presentation
  routing applies; banner / list / sound are all decided per
  the user's per-app settings.
- **Foreground delivery**: the notification fires while Roar
  is *still running* — typically only in the `--wait` flow,
  where Roar holds the runloop open to receive a click. In
  this case the framework asks Roar's delegate
  (`willPresent`) what presentation to use. By default Roar
  returns `[.banner, .list, .sound]`; the
  `--foreground-presentation` flag overrides that on a per-
  notification basis.

This distinction matters mainly for `--wait`: a notification
posted from `roar send --wait` is foreground-delivered while
the wait is alive, then transitions to "background" as soon
as Roar exits (post-click or post-timeout).

## The `--wait` lifecycle

`roar send --wait` does roughly:

1. Build the notification request.
2. Hop to the main actor, install Roar's app delegate as a
   subscriber for *this specific* `requestIdentifier`.
   (Subscribe-before-add ordering — an instant click can't
   race the subscription.)
3. Call `center.add(request)`. The notification is now in
   `usernoted`'s queue.
4. Await the next response from the delegate. Three sub-cases:
   - **Matching click or custom-action:** format the stdout
     line, print, drain XPC for ~100ms, then `exit(0)`. Done.
   - **`--wait-timeout` expiration:** print `timeout\n`, exit 2.
     Done.
   - **Unrelated click** (a different Roar notification still
     in Notification Center is clicked while we wait): ack the
     framework, drop the side effect, **loop back to step 4**
     and keep waiting for the request identifier we own.

Unrelated-click handling is what makes long `--wait` runs
robust against the user clicking other Roar notifications that
happen to still be in Notification Center while the script
waits. The wait owns its identifier exclusively.

## Click attribution and the `responsible_pid` problem

When `roar` is `exec`'d from Terminal (the common install
shape: `/opt/homebrew/bin/roar` symlinks into the bundle),
the kernel inherits the `responsible_pid` flag from Terminal.
`usernoted` uses that flag — not `Bundle.main.bundleIdentifier`
— to decide which icon to render on the notification banner.
Result: the banner shows Terminal's icon, even though every
other attribution route (auth grant, click handler, exit
behaviour) correctly resolves to Roar.

The private `responsibility_disclaim` API used to fix this
in-place. It was removed from macOS 26. The modern replacement
(`responsibility_spawnattrs_setdisclaim` + a `POSIX_SPAWN_SETEXEC`
re-exec) interacts badly with the hardened runtime on the
signed release build, and we couldn't debug it without
loosening the runtime restrictions in a way that defeats other
defences. So the wrong-icon limitation ships as-is. A child-spawn
variant (parent forwards stdio + signals to a disclaimed child)
remains an open avenue. See the comment block at the top of
`Sources/main.swift` and the git history around v0.1.6 / v0.1.7.

## XPC drain on exit

`UNUserNotificationCenter`'s `add(_:)`, `removeAll*`, and the
click-response completion handlers are all *fire-and-forget*
from Roar's side: the framework returns when the XPC request
has been *posted*, not when `usernoted` has *processed* it.
Calling `exit()` immediately after the framework call can race
the XPC flush and leave the request queued but undelivered (or
the click ack interpreted as abandoned).

Roar sleeps ~100ms before `Darwin.exit` on every terminal path
— enough for the XPC buffer to flush on any healthy system,
imperceptible to the user (the side effects have already
happened by then). The constant is
`RoarAppDelegate.exitDrainDelay`; the per-subcommand call
sites pull from there so future tuning lives in one place.

The drain is why `roar` always feels like it takes a beat to
exit after delivering. That's correct behaviour, not lag.

## Click handling

A click on a notification triggers a *bundle relaunch*. macOS
exec's `/Applications/Roar.app/Contents/MacOS/roar` with no
arguments and the click's `UNNotificationResponse` is delivered
to the relaunched process's delegate.

Roar disambiguates the two startup roles by inspecting
`getppid()` and `CommandLine.arguments`:

- **Bare invocation with `ppid == 1`**: relaunch from
  `launchd`-style click delivery. Wait up to 10 seconds for
  `didReceive`, then read the userInfo and route to the right
  side effect.
- **Any other invocation**: normal CLI. Run ArgumentParser,
  dispatch into the appropriate subcommand.

The 10-second fallback timer matters because cold-launched
bundles (Gatekeeper scan racing first-after-sleep activation)
can take several seconds to dispatch the delegate callback.
Empirically the worst observed dispatch latencies cluster around 
5-8 seconds.

## Output modes (text vs JSON)

Every subcommand has two output formats: a human-readable text
default and a structured JSON form (selected by `--json`).
**Exit codes are identical across modes**, so scripts that
branch on `$?` work unchanged when you flip the flag on.

The split exists for one reason — different consumers need
different shapes:

- **Humans + shell pipelines that already use `awk` / `grep`**:
  the text format. TSV for `list`, line-oriented `key: value`
  for `settings`, and the `--wait` text protocol
  (`<action>\n<text>?\n`) for interactive prompts.
- **Scripts that want a parser instead of a regex**: `--json`.
  Single-line, sorted-keys JSON ready for `jq`. Optional
  fields always appear as `null` rather than being omitted,
  so `jq '.text'` always returns a value.

Schemas are per-subcommand and stable scripting ABI — see each
subcommand's [reference page](reference/index.md) for the field
documentation. Cross-cutting overview and `jq` patterns in
[Scripting → JSON output](SCRIPTING.md#json-output-json).

## Permissions and distribution

How the three permission / entitlement / build-setting layers
relate, and how the local-dev / notarised-release / Homebrew-cask
trust channels differ, shape the *built artifact* rather than the
*concept* — covered in
[BUILD → Permissions, entitlements, build settings](BUILD.md#permissions-entitlements-build-settings)
and [BUILD → Distribution channels](BUILD.md#distribution-channels).

## Glossary

A short list of terms the docs use consistently, defined once
here so cross-references don't have to redefine them:

- **Roar** vs **`roar`**: `Roar` (capitalised) is the project /
  the `.app` bundle. `roar` (lowercase) is the CLI command
  symlinked onto your shell `PATH`.
- **Click handler**: the code path that runs when the user
  clicks a notification body — separate from the actions
  triggered by **custom action buttons** (the `--action` flag).
  The click handler dispatches to `--activate-bundle-id`,
  `--open-url`, or `--exec` based on what was set at send time.
- **Side effect** (or **click-time side effect**): the
  observable consequence of a click — opening a URL, running a
  shell command, activating an app. Same concept as the click
  handler's output; the docs use "click handler" for the code
  and "side effect" for the outcome.
- **Notification Center** (sometimes abbreviated **NC**): the
  slide-in UI surface at the top-right of the screen. View onto
  `usernoted`'s state, not its own storage.
- **Send time** vs **delivery time** vs **click time**: send
  time is when `roar send` parses flags and hands the request
  to `usernoted` (validation runs here). Delivery time is when
  the user sees the banner (for scheduled notifications this
  can be hours later). Click time is when the user actually
  taps the banner — Roar's click-handler relaunch runs here,
  and userInfo is re-validated.
- **Bundle id** (or **bundle identifier**): the reverse-DNS
  string the bundle registers with macOS. Roar's is
  `io.myers.roar`.
- **Category** / **`roar.dyn.<hash>`**: a notification category
  is the UN framework's grouping for action sets, lock-screen
  options, and the summary format. Roar mints category ids of
  the form `roar.dyn.<hash>` automatically — users never set
  them directly.

## Read next

- [Reference](reference/index.md) — every flag, every subcommand.
- [Cookbook](COOKBOOK.md) — recipes for common workflows.
- [Scripting](SCRIPTING.md) — the `--wait` protocol, exit-code
  dispatch, shell / Python / CI integration.
- [Security](SECURITY.md) — full threat model and every
  defence with rationale.
- [Troubleshooting](TROUBLESHOOTING.md) — symptom → fix.
- [FAQ](FAQ.md) — recurring questions about design and scope.
