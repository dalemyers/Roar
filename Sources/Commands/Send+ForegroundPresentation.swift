import ArgumentParser
import Foundation
import UserNotifications

extension Send {
    /// Resolved `--foreground-presentation` value. Bundles the parsed
    /// option set with the canonical serialized form so `Send.run()`
    /// can stash the string in userInfo and `RoarAppDelegate.willPresent`
    /// can parse the same string back into the same option set.
    ///
    /// Serialization (rather than storing `options.rawValue`) is
    /// deliberate: the raw bits of `UNNotificationPresentationOptions`
    /// are stable today, but the framework has previously deprecated /
    /// repurposed bits (`.alert` → `.banner`+`.list`), and the userInfo
    /// is read by whatever roar build the system happens to launch when
    /// `willPresent` fires — which may be a newer version than the
    /// poster. A name-based encoding survives the next rename.
    ///
    /// `serialized` is always non-empty: even the empty option set
    /// serialises to `"none"` so a reader can distinguish "user opted
    /// in to no options" from "no userInfo key at all" (the default).
    struct ForegroundPresentation: Equatable {
        let options: UNNotificationPresentationOptions
        let serialized: String

        // `UNNotificationPresentationOptions` is an `OptionSet` whose
        // `==` lives on `RawRepresentable`, not on a direct `Equatable`
        // conformance — synthesised `Equatable` doesn't always pick
        // that up cleanly across Swift versions. Spell it out so the
        // struct stays usable in `XCTAssertEqual` without surprise.
        static func == (lhs: ForegroundPresentation, rhs: ForegroundPresentation) -> Bool {
            lhs.options == rhs.options && lhs.serialized == rhs.serialized
        }
    }

    /// Recognised names for `--foreground-presentation` and their
    /// `UNNotificationPresentationOptions` mappings. `.alert` is NOT
    /// exposed — it was deprecated on macOS 11 in favour of `.banner`
    /// + `.list`, and accepting both would let users type values that
    /// silently do nothing on modern OS versions.
    static let foregroundPresentationOptionNames:
        [(name: String, bits: UNNotificationPresentationOptions)] = [
        ("banner", .banner),
        ("list", .list),
        ("sound", .sound),
        ("badge", .badge),
    ]

    /// Sentinel value the user supplies in place of any option name to
    /// request an explicitly empty presentation set (notification
    /// posts but is neither shown as a banner nor sounded nor badged).
    /// An empty string would otherwise be indistinguishable from "user
    /// passed `--foreground-presentation ""` by accident."
    static let foregroundPresentationNoneSentinel = "none"

    /// Parse the user-supplied `--foreground-presentation` array (one
    /// entry per `--foreground-presentation` flag occurrence; each
    /// entry is a single name from `banner`/`list`/`sound`/`badge`,
    /// or the literal `none`).
    ///
    /// The flag is repeat-flag-style (`--foreground-presentation
    /// banner --foreground-presentation list`) for consistency with
    /// `--attachment`, `--action`, `--text-action`. The previous
    /// comma-separated-in-a-single-string shape diverged from those
    /// peers and made `roar send` mixed CLI surfaces.
    ///
    /// Returns `nil` when the user did not pass the flag (the empty
    /// array — `[]`). The delegate then falls back to its hardcoded
    /// banner+list+sound+badge default. On a non-empty but malformed
    /// value, throws so the user sees a usage diagnostic at send time
    /// instead of a silent default at display time.
    ///
    /// Canonicalisation: the serialised form (still a comma-separated
    /// string, used as the userInfo storage shape) sorts the names in
    /// the order they appear in `foregroundPresentationOptionNames`.
    /// User input order is independent of the stored byte layout, so
    /// `[--foreground-presentation sound, --foreground-presentation
    /// banner]` round-trips through `"banner,sound"`. Determinism
    /// keeps `validateUserInfoSize` predictable across runs.
    ///
    /// `nonisolated static` so tests can pin the grammar without
    /// driving ArgumentParser.
    ///
    /// - Parameter names: The user-supplied `--foreground-presentation`
    ///   entries, in argv order.
    /// - Returns: A `ForegroundPresentation` carrying both the parsed
    ///   option set and its canonical string form, or `nil` if
    ///   `names` was empty.
    /// - Throws: `ValidationError` on per-entry whitespace/blank,
    ///   unknown names, the `none` sentinel (rejected outright — the
    ///   delegate refuses to honour an empty presentation set for
    ///   security reasons), or duplicate names across entries.
    static func parseForegroundPresentationOptions(
        _ names: [String]
    ) throws -> ForegroundPresentation? {
        // No flag = no override. Distinct from "one entry that
        // trimmed to empty" (that's an error — see below).
        guard !names.isEmpty else { return nil }
        var collectedNames: [String] = []
        var optionBits: UNNotificationPresentationOptions = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty entry — `--foreground-presentation ""` — is an
            // explicit mistake by the caller (ArgumentParser does
            // not silently drop empty values). Surface it instead of
            // silently treating it as "no override," which would hide
            // the user's intent.
            guard !name.isEmpty else {
                throw ValidationError(
                    "--foreground-presentation cannot have an empty "
                    + "entry. Pass one name per occurrence, e.g. "
                    + "--foreground-presentation banner --foreground-presentation list."
                )
            }
            if name == foregroundPresentationNoneSentinel {
                // The delegate-side deserializer refuses 'none' for
                // security reasons (an invisible-but-clickable
                // notification surface is the worst kind of foothold
                // for a same-bundle-id spoofer; see
                // `deserializeForegroundPresentationOptions`). When
                // the send-side parser accepted 'none' it produced a
                // silent display-time upgrade to defaults — a
                // legitimate `roar send --foreground-presentation none
                // --badge-count 5` invocation would fall through to
                // the framework's banner+list+sound+badge defaults
                // rather than the empty option set the user
                // requested, with no diagnostic. Reject at parse time
                // so the user sees the asymmetry at send time, and
                // can switch to the supported way to suppress
                // attention-grabbing presentation.
                throw ValidationError(
                    "--foreground-presentation 'none' is not supported. "
                    + "The delegate refuses to render an empty option set "
                    + "(an invisible-but-clickable notification is a "
                    + "phishing vector). To suppress banner break-through "
                    + "while still posting to Notification Center, pass "
                    + "'--interruption-level passive' instead."
                )
            }
            guard let entry = foregroundPresentationOptionNames.first(
                where: { $0.name == name }
            ) else {
                let known = foregroundPresentationOptionNames
                    .map(\.name).joined(separator: ", ")
                throw ValidationError(
                    "--foreground-presentation has an unknown option "
                    + "'\(name)'. Known options: \(known)."
                )
            }
            if collectedNames.contains(name) {
                throw ValidationError(
                    "--foreground-presentation lists '\(name)' more "
                    + "than once."
                )
            }
            collectedNames.append(name)
            optionBits.insert(entry.bits)
        }
        // Sort by the order in `foregroundPresentationOptionNames`
        // so the serialised string is deterministic regardless of
        // user input order. The lookup is O(n*m) but n,m ≤ 4.
        // The `none` branch is unreachable from here (it throws
        // above), so the canonical form is always the comma-joined
        // option list — the userInfo storage shape stays unchanged.
        let canonical = foregroundPresentationOptionNames
            .filter { collectedNames.contains($0.name) }
            .map(\.name)
            .joined(separator: ",")
        return ForegroundPresentation(options: optionBits, serialized: canonical)
    }

    /// Parse the canonical serialised form written by
    /// `parseForegroundPresentationOptions` back into the option set.
    /// Used by `RoarAppDelegate.willPresent` to apply a sender-supplied
    /// preference without re-running the user-facing validator.
    ///
    /// On any parse failure (corrupted userInfo, value posted by a
    /// non-roar process under the same bundle id, future roar build
    /// that added a name this build doesn't recognise), returns `nil`
    /// so the caller can fall through to the framework default rather
    /// than producing a confusing "options mismatched" failure mode.
    ///
    /// **`none` rejection.** The user-facing parser
    /// `parseForegroundPresentationOptions` accepts `"none"` as a
    /// canonical sentinel for an empty option set. The
    /// *deserialiser* does NOT — it deliberately returns `nil` so
    /// the delegate falls through to the default option set. The
    /// asymmetry is a security boundary, not a bug:
    ///
    /// * A notification posted with an empty presentation set is
    ///   visually invisible (no banner, no Notification Center entry,
    ///   no sound, no badge) but is still click-actionable. A
    ///   same-bundle-id spoofer could post a stealth notification
    ///   with `roar.present.options = "none"` plus a malicious
    ///   `roar.exec.command` (gated only by the `--allow-shell-on-click`
    ///   opt-in, which the spoofer can also set) and rely on the
    ///   user clicking somewhere on the banner-less surface to
    ///   trigger the command. The shell-on-click consent flag is the
    ///   send-time gate; the *visibility* gate is what prevents the
    ///   user from being tricked into clicking an invisible target.
    /// * Roar's own `--foreground-presentation none` is a legitimate
    ///   send-time preference (use cases: silently update a badge
    ///   count, post a record for `roar list` only). But that
    ///   preference is only ever consulted by `willPresent` when the
    ///   notification arrives *while this process is foreground*,
    ///   which is exactly the window where a stealth presentation is
    ///   most exploitable. The user receives no visual cue that a
    ///   notification was just posted under our bundle id.
    /// * The fallback when this returns `nil` is the framework
    ///   default (banner+list+sound+badge), which is the safe choice:
    ///   visible to the user, so a click can never happen against an
    ///   invisible surface.
    ///
    /// Roar callers that need a truly silent foreground notification
    /// should use `--interruption-level passive` or omit
    /// `--foreground-presentation` and let the system handle
    /// suppression based on Focus state. Suppressing the visual
    /// surface entirely via `none` is not honoured on the delegate
    /// side regardless of who set the userInfo.
    ///
    /// `nonisolated static` so the nonisolated delegate callback can
    /// invoke it without an actor hop.
    ///
    /// - Parameter serialized: The string previously stored under
    ///   `roar.present.options` in userInfo.
    /// - Returns: The option set, or `nil` if the string cannot be
    ///   interpreted *or* if it requested the `none` sentinel
    ///   (security: prevents invisible-but-clickable notifications).
    nonisolated static func deserializeForegroundPresentationOptions(
        _ serialized: String
    ) -> UNNotificationPresentationOptions? {
        // `none` is explicitly NOT honoured on the delegate side —
        // see method-level docstring for the security rationale.
        // Falling through to `nil` returns the framework default at
        // the call site, which is the safe choice (visible
        // notification, click can't happen against an invisible
        // surface).
        if serialized == foregroundPresentationNoneSentinel {
            return nil
        }
        // Empty input collapses to a zero-option result via the loop
        // below if not screened — that would silently match the
        // `.none` sentinel without the sender having opted in.
        // Reject it explicitly so the delegate falls through to the
        // default option set.
        guard !serialized.isEmpty else { return nil }
        var options: UNNotificationPresentationOptions = []
        for name in serialized.split(separator: ",") {
            let trimmed = String(name).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard let entry = foregroundPresentationOptionNames.first(
                where: { $0.name == trimmed }
            ) else {
                return nil
            }
            options.insert(entry.bits)
        }
        // A non-empty input that nevertheless collapses to a zero-
        // option set would only happen via a malformed entry that
        // somehow passed the lookup — defence in depth. Treat it the
        // same as `none`: return `nil` so the delegate falls back to
        // the default.
        if options.isEmpty { return nil }
        return options
    }
}
