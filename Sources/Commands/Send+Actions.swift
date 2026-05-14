import ArgumentParser
import Foundation
import UserNotifications

extension Send {
    /// Maximum number of `--action` buttons accepted. UN itself
    /// renders up to 4 buttons per category on macOS — additional
    /// actions are silently dropped, which is the worst kind of
    /// failure mode (configured buttons never appear and the user has
    /// no diagnostic). Cap at the platform limit so we can reject the
    /// 5th up-front with a clear message.
    static let maxActionCount = 4

    /// Stdout sentinel printed by `--wait` mode when the user clicked
    /// the notification body rather than a custom action button.
    /// Matches `UNNotificationDefaultActionIdentifier` semantically;
    /// reusing the framework constant verbatim would leak its
    /// `com.apple.UNNotificationDefaultActionIdentifier` shape into
    /// shell scripts, which is brittle if Apple ever renames it.
    static let waitDefaultSentinel = "default"

    /// Stdout sentinel printed by `--wait` mode when the user
    /// explicitly dismissed the notification (right-click → close,
    /// "X" affordance). Same renaming rationale as
    /// `waitDefaultSentinel`.
    static let waitDismissSentinel = "dismiss"

    /// Stdout sentinel printed by `--wait` mode when the
    /// `--wait-timeout` window elapsed without an interaction. The
    /// exit code is `2` to distinguish "user did nothing" from "user
    /// chose nothing" (default click that returns `0`) and from
    /// invalid arguments (ArgumentParser exits `64`).
    static let waitTimeoutSentinel = "timeout"

    /// Exit code used when `--wait-timeout` expires before a
    /// response arrives. Distinct from `0` (successful interaction),
    /// `1` (auth denial / side-effect failure), and ArgumentParser's
    /// `64` (EX_USAGE), so callers can branch on the meaning.
    static let waitTimeoutExitCode: Int32 = 2

    /// Exit code emitted when the user explicitly dismissed the
    /// notification in `--wait` mode (swipe-away / "X" / right-click
    /// → close). Distinct from the default-click success code (0) so
    /// shell scripts can branch on "the user actively rejected this"
    /// without having to parse stdout. The old behaviour exited 0 for
    /// both outcomes and forced consumers to inspect the printed
    /// sentinel, which most scripts skipped.
    ///
    /// Numerically separate from `waitTimeoutExitCode` (2), the
    /// generic auth/side-effect failure (1), and ArgumentParser's
    /// EX_USAGE (64), so the full code space — 0 / 1 / 2 / 3 / 64 —
    /// stays distinguishable.
    static let waitDismissExitCode: Int32 = 3

    /// Action ids reserved for the `--wait` stdout protocol. A user
    /// who registers `--action default:...` would otherwise produce
    /// stdout that's ambiguous with "the user clicked the body."
    static let reservedActionIDs: Set<String> = [
        waitDefaultSentinel, waitDismissSentinel
    ]

    /// Parsed `--action` / `--text-action` value: `id` is what gets
    /// printed to stdout in `--wait` mode, `title` is the button label
    /// shown in the notification, `options` carries the optional
    /// `::flag` suffix (destructive / auth-required), and `kind`
    /// distinguishes a plain push button from a text-input action.
    ///
    /// `Equatable` is provided for test assertions; `Hashable` is
    /// intentionally omitted because `UNNotificationActionOptions` is
    /// a bridged ObjC option set that only conforms to `Equatable`
    /// (via `RawRepresentable`), and synthesised `Hashable` would
    /// fail. Nothing in the codebase needs to hash a `ParsedAction`,
    /// so the omission has no cost. `Kind` stays a closed enum so
    /// adding a new kind is a compile error in every switch rather
    /// than a silent fallthrough.
    struct ParsedAction: Equatable {
        /// Distinguishes between a push-button action and a reply-style
        /// text-input action. Text-input carries a separate
        /// placeholder string and an inline send-button title because
        /// `UNTextInputNotificationAction.convenience init` requires
        /// both.
        enum Kind: Equatable {
            case button
            case textInput(placeholder: String, buttonTitle: String)
        }
        let id: String
        let title: String
        let options: UNNotificationActionOptions
        let kind: Kind

        /// Convenience used by older call sites and tests that didn't
        /// care about options/kind. Keeps the most common shape
        /// (`ParsedAction(id:title:)`) short.
        init(
            id: String,
            title: String,
            options: UNNotificationActionOptions = [],
            kind: Kind = .button
        ) {
            self.id = id
            self.title = title
            self.options = options
            self.kind = kind
        }
    }

    /// Named action flags accepted in the optional `::flag,flag` suffix
    /// of `--action` / `--text-action`. Map to `UNNotificationActionOptions`
    /// values. `.foreground` is intentionally absent — opening a window
    /// from this hidden bundle on click would surprise the user, and
    /// `--wait` already delivers the response inside this process
    /// without needing it.
    static let actionOptionNames: [String: UNNotificationActionOptions] = [
        "destructive": .destructive,
        "auth-required": .authenticationRequired,
    ]

    /// Parse the `flag,flag` portion of an `id:title::flags` action
    /// string. Each name must appear in `actionOptionNames`; duplicates
    /// and unknown names are rejected up-front so a typo doesn't
    /// silently produce a notification that lacks the intended
    /// affordance (UN ignores unknown bits in `UNNotificationActionOptions`).
    ///
    /// `nonisolated static` so tests can drive it without an Action
    /// invocation. Passes the full original `raw` string through to
    /// the error messages so the user sees what they typed, not the
    /// post-trim fragment.
    static func parseActionOptions(
        _ optionList: String, raw: String
    ) throws -> UNNotificationActionOptions {
        // Split on `,` and trim each entry's surrounding whitespace
        // (so 'destructive, auth-required' — natural to type — works).
        // Empty entries (after trimming) are rejected so `dest,` or
        // `,auth-required` don't silently accept a partial list.
        var options: UNNotificationActionOptions = []
        var seen = Set<String>()
        for part in optionList.split(
            separator: ",", omittingEmptySubsequences: false
        ) {
            let name = String(part).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw ValidationError(
                    "Action '\(raw)' has an empty flag in the '::' list "
                    + "(stray comma). Use a non-empty comma-separated list, "
                    + "e.g. destructive,auth-required."
                )
            }
            guard let option = actionOptionNames[name] else {
                let known = actionOptionNames.keys.sorted().joined(separator: ", ")
                throw ValidationError(
                    "Action '\(raw)' has an unknown flag '\(name)'. "
                    + "Known flags: \(known)."
                )
            }
            if !seen.insert(name).inserted {
                throw ValidationError(
                    "Action '\(raw)' lists flag '\(name)' more than once."
                )
            }
            options.insert(option)
        }
        return options
    }

    /// Internal split of `id:title[::flags]` shared by `parseActions`
    /// and `parseTextActions`. Returns the three components; the
    /// caller wraps them in a `ParsedAction` of the appropriate kind.
    ///
    /// - Parameters:
    ///   - raw: The user-supplied flag value.
    ///   - flagName: The flag's user-facing name, threaded into
    ///     error messages so the diagnostic matches the flag that
    ///     produced the value.
    /// - Returns: (id, title, options) parsed from `raw`.
    static func splitActionString(
        _ raw: String, flagName: String
    ) throws -> (id: String, title: String, options: UNNotificationActionOptions) {
        guard let colon = raw.firstIndex(of: ":") else {
            throw ValidationError(
                "\(flagName) '\(raw)' is missing a ':'. Expected form: "
                + "id:title (e.g. \(flagName) approve:Approve)."
            )
        }
        let id = String(raw[..<colon])
        let afterFirstColon = String(raw[raw.index(after: colon)...])

        // Detect the optional `::flag,flag` suffix. A single `::`
        // separates title from flags. Titles with single colons
        // ('Open: details') are unaffected because `::` is a two-byte
        // marker, not any `:`.
        //
        // Reject more than one `::` in the value: a user typing
        // `id:Title::dest::auth-required` (a plausible mistake given
        // the comma-separated flag-list format) would otherwise have
        // 'Title::dest' folded into the title and only `auth-required`
        // treated as a flag. Better to surface the typo than silently
        // mis-split.
        //
        // To embed a literal `::` in a title without flags, the
        // user can use a non-`::` colon sequence (e.g. single-spaced
        // `: :`) or omit the title's `::` entirely. Documented edge
        // case, unlikely to bite.
        let occurrences = afterFirstColon.ranges(of: "::")
        let title: String
        let options: UNNotificationActionOptions
        switch occurrences.count {
        case 0:
            title = afterFirstColon
            options = []
        case 1:
            let optsRange = occurrences[0]
            title = String(afterFirstColon[..<optsRange.lowerBound])
            let optsPart = String(afterFirstColon[optsRange.upperBound...])
            options = try parseActionOptions(optsPart, raw: raw)
        default:
            throw ValidationError(
                "\(flagName) '\(raw)' contains more than one '::' separator. "
                + "Use a single '::' before a single comma-separated flag list, "
                + "e.g. id:Title::destructive,auth-required."
            )
        }

        guard !id.isEmpty else {
            throw ValidationError("\(flagName) '\(raw)' has an empty id.")
        }
        guard !title.isEmpty else {
            throw ValidationError("\(flagName) '\(raw)' has an empty title.")
        }
        // Forbid whitespace and control characters in id. The id is
        // printed verbatim to stdout in --wait mode; embedded
        // whitespace would break `case` matching in shells, and a
        // NUL would truncate downstream C consumers (`xargs`, anything
        // reading via fgets).
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet.controlCharacters)
        if id.rangeOfCharacter(from: forbidden) != nil {
            throw ValidationError(
                "\(flagName) '\(raw)' has whitespace or a control character "
                + "in the id. Use a plain identifier like 'approve' or 'reject_v2'."
            )
        }
        if reservedActionIDs.contains(id) {
            throw ValidationError(
                "\(flagName) id '\(id)' is reserved (it's used to signal "
                + "the default click / explicit dismissal in --wait mode). "
                + "Choose a different id."
            )
        }
        return (id: id, title: title, options: options)
    }

    /// Parse and validate the `--action` array. The grammar is
    /// `id:title` split on the *first* `:` — titles containing
    /// colons are fine (`--action 'go:Open: details'`) but ids
    /// cannot. An optional `::flag,flag` suffix attaches
    /// `UNNotificationActionOptions` to the action; flags must come
    /// from `actionOptionNames` and the `::` must be the LAST in the
    /// value so a single-colon title is preserved verbatim.
    ///
    /// Ids must be unique within a single invocation (across both
    /// `--action` and `--text-action`, but that cross-check is the
    /// caller's responsibility — `parseActions` only screens within
    /// its own array), must not collide with the `--wait` stdout
    /// sentinels, and must not contain whitespace or control
    /// characters (NUL in particular would survive into the stdout
    /// protocol and break parsing on the receiving end).
    ///
    /// `nonisolated static` so tests can pin the grammar without
    /// driving ArgumentParser.
    ///
    /// - Parameter rawActions: The user-supplied `--action` strings.
    /// - Returns: An array of parsed actions, order preserved, kind=.button.
    /// - Throws: `ValidationError` on count > maxActionCount, missing
    ///   `:`, empty id or title, duplicate id, reserved id, forbidden
    ///   characters in id, or malformed `::flag,flag` suffix.
    static func parseActions(_ rawActions: [String]) throws -> [ParsedAction] {
        guard rawActions.count <= maxActionCount else {
            throw ValidationError(
                "--action supports at most \(maxActionCount) buttons "
                + "(received \(rawActions.count)). macOS silently drops the "
                + "rest, so additional buttons would never appear."
            )
        }
        var seen = Set<String>()
        var parsed: [ParsedAction] = []
        for raw in rawActions {
            let parts = try splitActionString(raw, flagName: "--action")
            if !seen.insert(parts.id).inserted {
                throw ValidationError(
                    "--action id '\(parts.id)' is used more than once. Each "
                    + "action must have a unique id."
                )
            }
            parsed.append(ParsedAction(
                id: parts.id,
                title: parts.title,
                options: parts.options,
                kind: .button
            ))
        }
        return parsed
    }

    /// Parse and validate the `--text-action` array. Same grammar as
    /// `--action` (`id:title[::flag,flag]`), but each entry produces a
    /// `ParsedAction` with `.textInput` kind so `buildCategory` knows
    /// to construct a `UNTextInputNotificationAction` instead of a
    /// plain `UNNotificationAction`.
    ///
    /// At most one text-input action per category is supported. UN
    /// itself permits multiple, but each needs its own placeholder /
    /// inline-button title; a single global `--text-placeholder`
    /// covers the common reply-style flow and avoids inventing a
    /// per-action flag for what is almost always one input.
    ///
    /// `nonisolated static` so tests can pin the grammar without
    /// driving ArgumentParser.
    ///
    /// - Parameters:
    ///   - rawActions: The user-supplied `--text-action` strings.
    ///   - placeholder: The shared `--text-placeholder` value.
    ///   - buttonTitle: The shared `--text-button-title` value, or a
    ///     blank string to let the system pick its default
    ///     (`UNTextInputNotificationAction` treats `""` as "use the
    ///     system default 'Send' label").
    /// - Returns: An array of parsed actions, order preserved, kind=.textInput.
    /// - Throws: `ValidationError` on count > 1, parser failure, or
    ///   any of the same shape errors as `parseActions`.
    static func parseTextActions(
        _ rawActions: [String],
        placeholder: String,
        buttonTitle: String
    ) throws -> [ParsedAction] {
        guard rawActions.count <= 1 else {
            throw ValidationError(
                "--text-action supports at most one text-input action per "
                + "notification (received \(rawActions.count)). Pick one; the "
                + "rest must be plain --action buttons."
            )
        }
        var parsed: [ParsedAction] = []
        for raw in rawActions {
            let parts = try splitActionString(raw, flagName: "--text-action")
            parsed.append(ParsedAction(
                id: parts.id,
                title: parts.title,
                options: parts.options,
                kind: .textInput(
                    placeholder: placeholder,
                    buttonTitle: buttonTitle
                )
            ))
        }
        return parsed
    }

    /// Cross-flag check: text-action ids must not collide with
    /// `--action` ids. Catches the case where a user re-uses the same
    /// id for a button and a text input — UN would accept it (the
    /// category would have two actions with the same identifier and
    /// the framework would silently keep one), but the `--wait` stdout
    /// protocol would be ambiguous on the receiving end.
    ///
    /// Also enforces the global cap of `maxActionCount` across both
    /// kinds combined, matching UN's per-category limit.
    static func validateActionIDUniqueness(
        buttons: [ParsedAction], textInputs: [ParsedAction]
    ) throws {
        let total = buttons.count + textInputs.count
        guard total <= maxActionCount else {
            throw ValidationError(
                "--action plus --text-action total \(total), but the "
                + "per-notification limit is \(maxActionCount). macOS silently "
                + "drops the overflow, so additional buttons would never appear."
            )
        }
        var seen = Set<String>()
        for action in buttons + textInputs {
            if !seen.insert(action.id).inserted {
                throw ValidationError(
                    "Action id '\(action.id)' is used more than once across "
                    + "--action and --text-action. Each id must be unique within "
                    + "the notification."
                )
            }
        }
    }

    /// Cross-flag validation for the `--action` / `--wait` /
    /// side-effect trio.
    ///
    /// Rules:
    /// * `--action` requires `--wait` — without it, a click on the
    ///   custom button has no scripted effect distinct from the
    ///   default click, which is almost never what the user meant.
    /// * `--wait` is mutually exclusive with `--exec` / `--open-url`
    ///   / `--activate-bundle-id` — the calling script captures the
    ///   action id from stdout and orchestrates side effects from
    ///   there, so running both wait-and-print AND fire-and-forget
    ///   side effects would split decision-making between Roar and
    ///   the caller in a confusing way.
    static func validateActionWaitCompatibility(
        actionsCount: Int,
        wait: Bool,
        exec: String?,
        openURL: String?,
        activateBundleID: String?
    ) throws {
        if actionsCount > 0, !wait {
            throw ValidationError(
                "--action / --text-action requires --wait. Without --wait, a "
                + "click on a custom button has no scripted effect different "
                + "from the default click. Add --wait to capture the chosen "
                + "action id (and any typed text) on stdout."
            )
        }
        guard wait else { return }
        var collisions: [String] = []
        if exec != nil { collisions.append("--exec") }
        if openURL != nil { collisions.append("--open-url") }
        if activateBundleID != nil { collisions.append("--activate-bundle-id") }
        guard collisions.isEmpty else {
            throw ValidationError(
                "--wait is mutually exclusive with \(collisions.joined(separator: ", ")). "
                + "In --wait mode the action id is printed to stdout and the calling "
                + "script handles side effects."
            )
        }
    }
}
