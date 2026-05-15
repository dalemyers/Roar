import ArgumentParser
import Foundation
import UserNotifications

extension Send {
    /// Validate `--open-url` early so we fail before posting a
    /// notification the click handler would later refuse to act on.
    ///
    /// Combines the default web/email allow-list with any
    /// `--allow-url-scheme` values the user explicitly typed, then
    /// validates the URL against the union. The combined allow-list
    /// is also returned so `buildUserInfo` can serialise it into
    /// userInfo for the click-time re-parse.
    ///
    /// Returns the parsed URL's canonical `absoluteString` rather
    /// than the `URL` value because the only downstream consumer is
    /// the `roar.open.url` userInfo field, which is a `String`.
    ///
    /// - Returns: A tuple of the serialised URL and the exact
    ///   allow-list used. `nil` if `--open-url` was not supplied
    ///   (in which case `--allow-url-scheme` is also irrelevant).
    /// - Throws: `ValidationError` (wrapped `URLValidation.Error`)
    ///   if the URL or any scheme-name addition is malformed, or
    ///   the URL's scheme is not in the combined allow-list.
    func validateOpenURLIfPresent() throws
        -> (absoluteString: String, allowList: Set<String>)? {
        guard let openURL else { return nil }
        do {
            let allowList = try URLValidation.buildAllowList(
                additions: allowUrlScheme)
            let absolute = try URLValidation.parse(
                openURL, allowedSchemes: allowList).absoluteString
            return (absoluteString: absolute, allowList: allowList)
        } catch let error as URLValidation.Error {
            // Surface as ValidationError so ArgumentParser exits with
            // EX_USAGE (64) and prints the usage hint, matching how the
            // other --option validators report failure.
            throw ValidationError(error.description)
        }
    }

    /// Validate `--allow-url-scheme` even when `--open-url` isn't set
    /// so a typo'd `--allow-url-scheme "java script"` doesn't slip
    /// through silently. (Without `--open-url` the user-supplied
    /// scheme set has nowhere to flow, but accepting bogus values
    /// teaches users that the flag is permissive — which it isn't.)
    ///
    /// `nonisolated static` so tests can pin the rule.
    static func validateAllowUrlSchemeNames(_ raw: [String]) throws {
        for name in raw {
            do {
                _ = try URLValidation.validateSchemeName(name)
            } catch let error as URLValidation.Error {
                throw ValidationError(error.description)
            }
        }
    }

    /// Require an explicit opt-in flag when `--exec` is set. The
    /// notification body is independent of the executed command, so a
    /// notification reading "Build complete" could otherwise run an
    /// unrelated shell payload on click without the user realising it.
    ///
    /// - Throws: `ValidationError` if `--exec` is set without
    ///   `--allow-shell-on-click`.
    func validateExecOptIn() throws {
        try Self.validateExecOptIn(exec: exec, allowShellOnClick: allowShellOnClick)
    }

    /// Pure-function counterpart to the instance method, exposed so
    /// tests can pin the policy without spinning up an ArgumentParser
    /// invocation that would call `Darwin.exit` on success.
    ///
    /// Also rejects embedded NUL bytes: the click-handler spawns the
    /// command through `posix_spawn`, which builds its argv with
    /// `strdup`. `strdup` is a C-string copy and truncates at the
    /// first NUL — so a command like `"echo ok\0; rm -rf $HOME"`
    /// would silently run only the prefix, while the visible / debug-
    /// logged value shows the full string. Reject NUL up-front so
    /// what the user sees is what runs.
    ///
    /// - Parameters:
    ///   - exec: The `--exec` value, or `nil` if absent.
    ///   - allowShellOnClick: The `--allow-shell-on-click` flag value.
    /// - Throws: `ValidationError` if `exec` contains a NUL byte,
    ///   or is non-nil and `allowShellOnClick` is `false`.
    static func validateExecOptIn(exec: String?, allowShellOnClick: Bool) throws {
        guard let exec else { return }
        // Reject empty before the opt-in / NUL checks. An empty
        // `--exec ""` would otherwise pass NUL screening (no NUL in
        // empty string), set `roar.exec.consent = "1"` in the userInfo,
        // and the click handler would then run `/bin/sh -c "cd ...; "`
        // — a no-op shell invocation that consumes the opt-in for no
        // purpose. Worse, a same-bundle-id spoofer could use the
        // no-op as a click-detection oracle (exit-code 0 on click,
        // never on dismiss) since `--exec ""` is otherwise silently
        // accepted.
        guard !exec.isEmpty else {
            throw ValidationError(
                "--exec cannot be empty. Provide a shell command, or omit "
                + "the flag entirely."
            )
        }
        guard !exec.contains("\0") else {
            throw ValidationError(
                "--exec cannot contain NUL bytes — the shell-exec C bridge "
                + "truncates at NUL, which would silently change the command "
                + "actually executed."
            )
        }
        guard allowShellOnClick else {
            throw ValidationError(
                "--exec runs a shell command when the notification is clicked. "
                + "Re-run with --allow-shell-on-click to acknowledge this."
            )
        }
    }

    /// Validate `--sound` against the known sound locations.
    /// `UNNotificationSound(named:)` is non-fallible and silently falls
    /// back when the name doesn't resolve, so a typo (e.g. `Hero` vs
    /// `Glass`) produces a silent notification with no diagnostic.
    ///
    /// The sound name is rejected outright if it contains a path
    /// separator or starts with `.` — `appendingPathComponent` does no
    /// sanitisation, so a value like `"../../etc/passwd"` would
    /// otherwise probe arbitrary filesystem locations and (worse)
    /// "validate" successfully when an unrelated file happens to exist.
    ///
    /// Only system-installed sound directories are checked.
    /// `~/Library/Sounds` was previously included, but the
    /// UserNotifications framework doesn't resolve names from a user's
    /// home — including it produced false positives where validation
    /// passed but the notification still played silently.
    ///
    /// - Throws: `ValidationError` if the sound name contains path
    ///   syntax, or if a non-`default` name does not correspond to a
    ///   file in any standard sound directory.
    func validateSoundIfPresent() throws {
        guard let sound else { return }
        try Self.validateSoundName(sound)
    }

    func validateAttachmentIfPresent() throws {
        // The thumbnail flags must be screened even when no
        // `--attachment` was passed — that's the case where they would
        // otherwise pass silently and surprise the user. Run the
        // flag-vs-attachment check first so the more useful "no
        // effect without --attachment" message wins over a downstream
        // "could not read attachment."
        try Self.validateThumbnailFlagsRequireAttachment(
            attachments: attachment,
            noThumbnail: noThumbnail,
            thumbnailTime: thumbnailTime
        )
        try Self.validateThumbnailTime(thumbnailTime)
        try Self.validateAttachmentCount(attachment)
        // Each `--attachment` is validated independently — repeating
        // the flag is shorthand for "post these N", not "post one";
        // each value goes through the same path/existence/symlink
        // discipline the singular form had.
        for path in attachment {
            try Self.validateAttachmentPath(path)
            try Self.validateAttachmentExistsIfLocal(path)
        }
    }

    /// Maximum number of `--attachment` flags accepted on a single
    /// `roar send`. UN imposes a system-defined per-notification cap
    /// that varies by attachment kind and total payload size; in
    /// practice the framework starts dropping attachments past a
    /// small number (most documented references say ~10 for images),
    /// so the CLI rejects requests well over that with a clear
    /// error rather than silently letting the framework discard the
    /// tail of the user's list.
    static let maximumAttachmentCount = 10

    /// Reject `--attachment` lists longer than the per-notification
    /// cap. An empty list is the no-flag case and is fine.
    ///
    /// `nonisolated static` so tests can pin the rule without
    /// constructing a real `Send`.
    static func validateAttachmentCount(_ attachments: [String]) throws {
        guard attachments.count <= maximumAttachmentCount else {
            throw ValidationError(
                "Too many --attachment values (\(attachments.count)); "
                + "the per-notification limit is \(maximumAttachmentCount). "
                + "Drop the extras or split into multiple `roar send` calls."
            )
        }
    }

    /// Reject negative / non-finite `--thumbnail-time` values. `nil`
    /// means the user did not pass the flag; nothing to check.
    /// `UNNotificationAttachmentOptionsThumbnailTimeKey` documents the
    /// value as a non-negative number of seconds, but silently clamps
    /// or ignores out-of-range input.
    ///
    /// - Parameter time: The user-supplied `--thumbnail-time` value,
    ///   or `nil` if absent.
    /// - Throws: `ValidationError` if non-nil and non-finite or
    ///   negative.
    static func validateThumbnailTime(_ time: Double?) throws {
        guard let time else { return }
        guard time.isFinite else {
            throw ValidationError(
                "--thumbnail-time must be a finite number of seconds (got \(time))."
            )
        }
        guard time >= 0 else {
            throw ValidationError(
                "--thumbnail-time must be >= 0 (got \(time))."
            )
        }
    }

    /// Reject `--attachment-type-hint` when empty / whitespace-only or
    /// passed without any `--attachment`. UN silently ignores
    /// attachment options when there is no attachment, so a value
    /// supplied in isolation would never reach the framework — same
    /// surprise as the thumbnail flags.
    ///
    /// Returns the trimmed value so the call site can thread it
    /// downstream into the attachment options dict. Without binding
    /// the trimmed return, a value like `" public.png "` would
    /// validate cleanly but the un-trimmed property would land in
    /// `UNNotificationAttachmentOptionsTypeHintKey`, which UN compares
    /// against UTI strings byte-for-byte — surrounding whitespace
    /// would silently disable type-hinting.
    ///
    /// `nonisolated static` so tests can pin the rule without driving
    /// ArgumentParser.
    ///
    /// - Parameters:
    ///   - hint: The user-supplied `--attachment-type-hint` value, or
    ///     `nil` if absent.
    ///   - attachments: The `--attachment` array (after empty-string
    ///     filtering, if any). Used only to detect the no-attachment
    ///     case.
    /// - Returns: The trimmed hint, or `nil` if `hint` was `nil`.
    /// - Throws: `ValidationError` if `hint` is non-nil but trims to
    ///   empty, or if `hint` is non-nil and `attachments` is empty.
    @discardableResult
    static func validateAttachmentTypeHint(
        _ hint: String?,
        attachments: [String]
    ) throws -> String? {
        let trimmed = try SharedValidation.requireNonBlank(
            hint,
            flag: "--attachment-type-hint",
            emptyAdvice: "Provide a UTI (e.g. public.png), or omit the flag entirely."
        )
        guard trimmed != nil else { return nil }
        guard !attachments.isEmpty else {
            throw ValidationError(
                "--attachment-type-hint has no effect without --attachment."
            )
        }
        return trimmed
    }

    /// Reject `--filter-criteria` when empty / whitespace-only,
    /// containing control characters, or exceeding
    /// `maximumIdentifierLength`. The UN framework treats `nil` and
    /// `""` distinctly: `nil` means "no Focus filter hint," `""`
    /// means "match the empty-string filter," which is almost never
    /// what the user wants.
    ///
    /// The control-character / length checks mirror
    /// `validateRequestIdentifier`: this value lands in
    /// `UNMutableNotificationContent.filterCriteria` which is XPC-
    /// serialised as a string field with the same C-bridge truncation
    /// hazard at NUL, and an unbounded value would be rejected by UN
    /// with an opaque "internal error" rather than a clean
    /// diagnostic.
    ///
    /// Returns the trimmed value so the call site can thread it
    /// downstream into `content.filterCriteria`. Without binding
    /// the trimmed return, `" focus-key "` would validate cleanly
    /// but the un-trimmed property would land in the framework, and
    /// the Focus engine compares the criteria byte-for-byte — the
    /// trailing whitespace silently disables every Focus rule that
    /// expected the clean key.
    ///
    /// `nonisolated static` so tests can pin the rule.
    ///
    /// - Parameter criteria: The user-supplied `--filter-criteria`
    ///   value, or `nil` if absent.
    /// - Returns: The trimmed criteria, or `nil` if `criteria` was
    ///   `nil`.
    /// - Throws: `ValidationError` if non-nil but malformed.
    @discardableResult
    static func validateFilterCriteria(_ criteria: String?) throws -> String? {
        let trimmed = try SharedValidation.requireNonBlank(
            criteria,
            flag: "--filter-criteria",
            emptyAdvice: "Provide a non-empty string, or omit the flag entirely.",
            rejectControlCharacters: true
        )
        guard let trimmed else { return nil }
        guard trimmed.count <= maximumIdentifierLength else {
            throw ValidationError(
                "--filter-criteria exceeds the \(maximumIdentifierLength)-character "
                + "limit (got \(trimmed.count)). Shorten the value."
            )
        }
        return trimmed
    }

    /// Reject `--no-thumbnail` / `--thumbnail-time` when there is no
    /// `--attachment` to apply them to. UN silently ignores attachment
    /// options when there is no attachment; surface the misuse instead
    /// so the user notices the flag wasn't doing what they expected.
    ///
    /// Both options apply uniformly to *all* attachments when multiple
    /// `--attachment` values are passed (the CLI keeps the per-flag
    /// option singular). The check is therefore on the array being
    /// empty rather than on a single optional.
    static func validateThumbnailFlagsRequireAttachment(
        attachments: [String],
        noThumbnail: Bool,
        thumbnailTime: Double?
    ) throws {
        guard attachments.isEmpty else { return }
        if noThumbnail {
            throw ValidationError(
                "--no-thumbnail has no effect without --attachment."
            )
        }
        if thumbnailTime != nil {
            throw ValidationError(
                "--thumbnail-time has no effect without --attachment."
            )
        }
    }

    /// Reject an empty `--activate-bundle-id ""`. The empty string would
    /// otherwise land in `userInfo["roar.activate.bundleID"]`, and the click
    /// handler would hit `urlForApplication(withBundleIdentifier: "")` and
    /// report "Activate target not found." Surface the malformed input at
    /// send time with a clearer message instead.
    ///
    /// Whitespace-only values (e.g. `--activate-bundle-id '   '`) are also
    /// rejected: a bundle identifier is a dotted reverse-DNS string
    /// (`com.example.app`) and cannot contain whitespace, so the input
    /// is unambiguously malformed.
    ///
    /// Returns the trimmed value so the call site can thread it into
    /// the click-handler `userInfo` dict. Without binding the trim,
    /// a value like `" com.apple.Safari "` would validate cleanly but
    /// `urlForApplication(withBundleIdentifier:)` does an exact
    /// match on the LaunchServices registration — trailing whitespace
    /// would silently fail the lookup with "Activate target not found"
    /// at click time, defeating the whole point of this validator.
    func validateActivateBundleIDIfPresent() throws -> String? {
        return try Self.validateActivateBundleID(activateBundleID)
    }

    /// Pure-function counterpart so tests can pin the rules without
    /// constructing a full `Send` invocation. `nil` means the user
    /// didn't pass `--activate-bundle-id`; in that case there is nothing
    /// to validate.
    ///
    /// - Parameter activateBundleID: The user-supplied
    ///   `--activate-bundle-id` value, or `nil` if absent.
    /// - Returns: The trimmed bundle id, or `nil` if `activateBundleID`
    ///   was `nil`.
    /// - Throws: `ValidationError` if `activateBundleID` is non-nil but
    ///   empty or whitespace-only.
    @discardableResult
    static func validateActivateBundleID(_ activateBundleID: String?) throws -> String? {
        // Bundle id rides in userInfo and is later passed to
        // `NSWorkspace.openApplication(at:)` / launch-services lookup —
        // a NUL would truncate downstream and silently activate a
        // different bundle than the user typed. Same rationale as
        // `validateRequestIdentifier`.
        return try SharedValidation.requireNonBlank(
            activateBundleID,
            flag: "--activate-bundle-id",
            emptyAdvice:
                "Provide a bundle identifier (e.g. com.apple.Safari), "
                + "or omit the flag entirely.",
            rejectControlCharacters: true
        )
    }

    /// Reject empty / whitespace-only `--thread-id`. Same shape as the
    /// other "non-nil-but-trivial" rejections — the UN framework would
    /// otherwise accept the value silently and not group anything,
    /// surprising the user.
    ///
    /// Returns the trimmed value so the call site can thread it into
    /// `content.threadIdentifier`. Without binding the trim, a value
    /// like `" build-results "` would validate cleanly but UN groups
    /// notifications by exact-string match on the thread id — the
    /// trailing whitespace would silently land a notification in a
    /// different bucket from notifications posted with the clean key.
    func validateThreadIDIfPresent() throws -> String? {
        return try Self.validateThreadID(threadID)
    }

    /// Maximum length of a `--identifier` value. UN's documented limit
    /// is "system-defined" — empirical probing of `usernoted`'s XPC
    /// surface accepts up to ~256 characters cleanly; longer values
    /// produce a vague "internal error" from `add(_:)` that is not
    /// useful to users. Capping at 256 surfaces a clear, fast error
    /// rather than a downstream mystery.
    static let maximumIdentifierLength = 256

    /// Reject malformed identifier values: empty / whitespace-only,
    /// containing NUL or other control characters, or longer than
    /// `maximumIdentifierLength`.
    ///
    /// Used for both `--identifier` (the UN request id) and
    /// `--target-content-id` (the click-handoff hint). Both feed into
    /// XPC-serialised string fields with the same C-bridge truncation
    /// hazard at NUL, so the rules are identical; the `flagName`
    /// parameter just personalises the error message.
    ///
    /// The identifier is the key UN uses for replace, dismiss, and
    /// list lookups — so silent corruption of it propagates to
    /// downstream commands. NUL is especially bad because the C-string
    /// bridge for XPC serialization truncates at the first NUL,
    /// meaning the visible identifier and the persisted identifier
    /// would diverge.
    ///
    /// `nonisolated static` so tests can pin the rules without driving
    /// ArgumentParser.
    ///
    /// - Parameters:
    ///   - identifier: The user-supplied identifier value, or `nil`
    ///     if absent.
    ///   - flagName: The flag's user-facing name. Defaults to
    ///     `--identifier` so existing call sites and tests need no
    ///     change.
    /// - Throws: `ValidationError` on any malformed shape.
    @discardableResult
    static func validateRequestIdentifier(
        _ identifier: String?,
        flagName: String = "--identifier"
    ) throws -> String? {
        // Capture the trimmed value so the call site can thread it
        // into the request id / target-content-id sink — without the
        // bind, `--identifier ' foo '` would validate cleanly but the
        // un-trimmed string would land in `UNNotificationRequest.identifier`,
        // which UN compares byte-for-byte on replace / dismiss / list.
        // Reposting the "same" identifier later would mint a second
        // notification rather than replacing the first.
        let trimmed = try SharedValidation.requireNonBlank(
            identifier,
            flag: flagName,
            emptyAdvice: "Provide a non-empty identifier, or omit the flag entirely.",
            rejectControlCharacters: true
        )
        guard let trimmed else { return nil }
        guard trimmed.count <= maximumIdentifierLength else {
            throw ValidationError(
                "\(flagName) exceeds the \(maximumIdentifierLength)-character "
                + "limit (got \(trimmed.count)). Shorten the identifier."
            )
        }
        return trimmed
    }

    /// Pure-function counterpart for tests.
    ///
    /// The control-character / length checks mirror
    /// `validateRequestIdentifier`: `--thread-id` lands in
    /// `UNMutableNotificationContent.threadIdentifier`, which is
    /// XPC-serialised as a string field with the same C-bridge
    /// truncation hazard at NUL. A NUL in the thread id would silently
    /// truncate at the XPC bridge, so the visible thread id and the
    /// grouped-thread id would diverge — notifications would land in
    /// an unexpected thread bucket.
    ///
    /// - Parameter threadID: The user-supplied `--thread-id` value, or
    ///   `nil` if absent.
    /// - Returns: The trimmed identifier, or `nil` if `threadID` was
    ///   `nil`.
    /// - Throws: `ValidationError` if non-nil but malformed.
    @discardableResult
    static func validateThreadID(_ threadID: String?) throws -> String? {
        let trimmed = try SharedValidation.requireNonBlank(
            threadID,
            flag: "--thread-id",
            emptyAdvice:
                "Provide a thread identifier (e.g. 'build-results'), "
                + "or omit the flag entirely.",
            rejectControlCharacters: true
        )
        guard let trimmed else { return nil }
        guard trimmed.count <= maximumIdentifierLength else {
            throw ValidationError(
                "--thread-id exceeds the \(maximumIdentifierLength)-character "
                + "limit (got \(trimmed.count)). Shorten the identifier."
            )
        }
        return trimmed
    }

    /// Title used when the user does not pass `--title`. Pulled from
    /// the machine's user-visible name (System Settings → General →
    /// About → Name) where possible, falling back to the short hostname
    /// (`mymac` from `mymac.local`) and finally to the literal
    /// `"Notification"` if both lookups are unavailable.
    ///
    /// The previous default was the literal string `"Roar"` — the
    /// tool's own name, which baked an irrelevant brand into every
    /// notification body and surprised first-run users. Pulling from
    /// system identity gives a default that's at least informative
    /// (which machine sent this) and matches what other notification-
    /// posting tools (Apple Mail, etc.) put in the same slot.
    ///
    /// `nonisolated static` so the resolver in `Send.run()` can call
    /// it without an actor hop.
    static func defaultTitle() -> String {
        if let localized = Host.current().localizedName, !localized.isEmpty {
            return localized
        }
        let hostName = ProcessInfo.processInfo.hostName
        if let short = hostName.split(separator: ".").first.map(String.init),
           !short.isEmpty {
            return short
        }
        if !hostName.isEmpty { return hostName }
        return "Notification"
    }

    /// Reject NUL bytes in the notification title. The title lands in
    /// `UNMutableNotificationContent.title`, which is XPC-serialised as
    /// a C-bridged string field — an embedded NUL truncates at the
    /// bridge, producing a visible title that diverges from the value
    /// the user typed.
    ///
    /// Only NUL is screened (not the broader `CharacterSet.controlCharacters`):
    /// the title is a free-form user-facing string that legitimately
    /// carries newlines (multi-line title in the banner), tabs
    /// (alignment), and other formatting controls. UN renders most of
    /// them as printable whitespace. NUL is the specific hazard that
    /// breaks the XPC C-string bridge; the others are display quirks,
    /// not corruption.
    ///
    /// `nonisolated static` so tests can pin the rule without driving
    /// ArgumentParser.
    ///
    /// - Parameter title: The resolved title (either the user-supplied
    ///   `--title` value, or `defaultTitle()` when the flag was omitted).
    ///   The caller is responsible for resolving the default; this
    ///   validator only screens the bytes that will reach the framework.
    /// - Throws: `ValidationError` if the title contains a NUL byte.
    /// Per-field UTF-8 byte cap for `--title` / `--subtitle` /
    /// `--body`. Sized at 4 KB so the legitimate ceiling (a couple
    /// of paragraphs of body text, a multi-line title) sails through
    /// while the abuse shape (megabyte-scale strings passed via
    /// `--title "$REMOTE_DATA"` from a script that didn't bound
    /// untrusted input) is rejected before hitting the UN XPC
    /// bridge. UN itself enforces an internal limit, but its error
    /// is opaque ("an unexpected error occurred"); failing at the
    /// validator gives the user a diagnostic they can act on. The
    /// dedicated `validateUserInfoSize` cap (16 KB serialised dict)
    /// does NOT cover these fields — they go to `content.title`,
    /// `content.subtitle`, `content.body` directly.
    static let visibleContentByteCap: Int = 4 * 1024

    /// Shared screen for `--title` / `--subtitle` / `--body` byte
    /// length. Counting `.utf8.count` rather than `.count` is
    /// load-bearing: `String.count` reports extended-grapheme units
    /// (one per visible character), while the XPC payload pays per
    /// UTF-8 byte. A 4-KB-grapheme emoji string can be >16 KB on
    /// the wire — bound the actual transport cost.
    ///
    /// `nonisolated static` so tests can pin the rule.
    static func enforceVisibleContentByteCap(
        _ value: String, flag: String
    ) throws {
        let bytes = value.utf8.count
        guard bytes <= visibleContentByteCap else {
            throw ValidationError(
                "\(flag) is \(bytes) bytes; the maximum is "
                + "\(visibleContentByteCap) bytes. Notification fields "
                + "are designed for short user-facing strings — paste "
                + "large content into a file and `--open-url file://...` "
                + "or `--attachment` instead."
            )
        }
    }

    static func validateTitle(_ title: String) throws {
        if title.contains("\0") {
            throw ValidationError(
                "--title cannot contain NUL (\\0) bytes. NUL truncates "
                + "downstream string consumers via the XPC C-string bridge."
            )
        }
        try enforceVisibleContentByteCap(title, flag: "--title")
    }

    /// Reject NUL bytes in `--subtitle`. Same C-bridge truncation
    /// hazard as `--title`; `nil` means the flag wasn't passed and
    /// there's nothing to check.
    ///
    /// NUL-only (not all `controlCharacters`) for the same reason as
    /// `validateTitle`: newlines / tabs are legitimate display content
    /// in a free-form subtitle.
    ///
    /// `nonisolated static` so tests can pin the rule.
    ///
    /// - Parameter subtitle: The user-supplied `--subtitle` value, or
    ///   `nil` if absent.
    /// - Throws: `ValidationError` if non-nil and contains a NUL byte
    ///   or exceeds `visibleContentByteCap`.
    static func validateSubtitle(_ subtitle: String?) throws {
        guard let subtitle else { return }
        if subtitle.contains("\0") {
            throw ValidationError(
                "--subtitle cannot contain NUL (\\0) bytes. NUL truncates "
                + "downstream string consumers via the XPC C-string bridge."
            )
        }
        try enforceVisibleContentByteCap(subtitle, flag: "--subtitle")
    }

    /// Apply the visible-content byte cap to a resolved `--body`
    /// value. The body has its own size discipline upstream
    /// (`resolveBody` enforces a 1 MB stdin-read cap), but the
    /// argument-form value (`--body "..."`) bypasses that read cap
    /// entirely. The 4 KB cap mirrors the title/subtitle constraint
    /// so a multi-megabyte argument-form body can't slip into the
    /// XPC payload either. Apply this AFTER `resolveBody` so both
    /// the argument and stdin shapes get the same screen.
    ///
    /// - Throws: `ValidationError` if the body exceeds the cap.
    static func validateResolvedBodySize(_ body: String) throws {
        try enforceVisibleContentByteCap(body, flag: "--body")
    }

    /// Reject `--relevance-score` outside the closed range [0.0, 1.0],
    /// or non-finite values (NaN, ±Infinity).
    ///
    /// `UNMutableNotificationContent.relevanceScore` documents the
    /// accepted range and clamps silently otherwise — a typo like
    /// `--relevance-score 10` (intending "10%" but writing the
    /// percent value) would be accepted and the user would never see
    /// a diagnostic. Same shape as the other "non-nil but invalid"
    /// rejections in this file.
    func validateRelevanceScoreIfPresent() throws {
        try Self.validateRelevanceScore(relevanceScore)
    }

    /// Pure-function counterpart for tests. `nil` means the user did
    /// not pass `--relevance-score`; nothing to validate.
    ///
    /// - Parameter score: The user-supplied `--relevance-score` value.
    /// - Throws: `ValidationError` if non-nil and outside [0.0, 1.0],
    ///   or non-finite.
    static func validateRelevanceScore(_ score: Double?) throws {
        guard let score else { return }
        guard score.isFinite else {
            throw ValidationError(
                "--relevance-score must be a finite number between 0.0 and 1.0 "
                + "(got \(score))."
            )
        }
        guard (0.0...1.0).contains(score) else {
            throw ValidationError(
                "--relevance-score must be between 0.0 and 1.0 inclusive "
                + "(got \(score))."
            )
        }
    }

    /// Reject `--text-placeholder` / `--text-button-title` when no
    /// `--text-action` was supplied. UN silently ignores the values
    /// in that case; surface the misuse so the user notices.
    static func validateTextSideOptions(
        textActions: [String],
        textPlaceholder: String?,
        textButtonTitle: String?
    ) throws {
        guard textActions.isEmpty else { return }
        if textPlaceholder != nil {
            throw ValidationError(
                "--text-placeholder has no effect without --text-action."
            )
        }
        if textButtonTitle != nil {
            throw ValidationError(
                "--text-button-title has no effect without --text-action."
            )
        }
    }

    /// Fallback timeout when `--wait` is set but `--wait-timeout` is
    /// omitted. 5 minutes is long enough that interactive use isn't
    /// rushed (the user has time to actually look at the banner)
    /// while still bounding unattended scripts: a forgotten `roar send
    /// --wait` invocation in CI used to hang forever and tie up the
    /// runner until somebody cancelled the job. Pre-default the user
    /// can still set a longer value (`--wait-timeout 1h`, etc.) up to
    /// `maximumScheduleInterval`.
    static let defaultWaitTimeoutSeconds: TimeInterval = 5 * 60

    /// Validate `--wait-timeout` value: must be a positive duration
    /// in the same `<number><unit>` format as `--in`, and only
    /// meaningful when `--wait` is set. Returns the parsed
    /// `TimeInterval` so callers can thread the value into the await
    /// site without re-parsing.
    ///
    /// When `--wait` is set and `--wait-timeout` is omitted, the
    /// validator substitutes `defaultWaitTimeoutSeconds` (5 minutes)
    /// rather than returning `nil`. A `nil` return historically meant
    /// "wait forever," which made forgotten `roar send --wait`
    /// invocations in CI hang until somebody noticed. Users who want
    /// a longer wait pass `--wait-timeout 1h` (or up to the
    /// `maximumScheduleInterval` ceiling of 365d).
    ///
    /// Returning the parsed value (rather than discarding it and
    /// re-running `parseScheduleInterval` at the consumer) closes a
    /// drift hazard: if the validator and the consumer ever fall out
    /// of sync (e.g. a future grammar refactor tightens the regex on
    /// one side only), a `try?`-swallowed re-parse would silently
    /// disable the timeout and the calling CI job would hang
    /// indefinitely. One parse, one source of truth.
    ///
    /// `nonisolated static` so tests can pin the rule.
    ///
    /// - Parameters:
    ///   - waitTimeout: The user-supplied `--wait-timeout` value, or
    ///     `nil` if the flag was omitted.
    ///   - wait: Whether `--wait` was set. `--wait-timeout` without
    ///     `--wait` is a usage error.
    /// - Returns: The parsed `TimeInterval` when `waitTimeout` is
    ///   non-nil and valid; `defaultWaitTimeoutSeconds` when `wait`
    ///   is set and `waitTimeout` is `nil`; `nil` when `wait` is
    ///   `false` and `waitTimeout` is `nil`.
    /// - Throws: `ValidationError` on the misuse or parse paths.
    @discardableResult
    static func validateWaitTimeout(
        waitTimeout: String?, wait: Bool
    ) throws -> TimeInterval? {
        guard let waitTimeout else {
            // No flag passed. If `--wait` is set, fall back to the
            // built-in 5-minute default so the consumer enforces a
            // ceiling; otherwise return nil (the value is irrelevant
            // when `--wait` is off and the call site doesn't consult
            // it).
            return wait ? defaultWaitTimeoutSeconds : nil
        }
        guard wait else {
            throw ValidationError(
                "--wait-timeout has no effect without --wait. Add --wait, or "
                + "drop --wait-timeout."
            )
        }
        // Reuse `parseScheduleInterval` so the format and the
        // minimum-interval floor are identical to `--in`. The parsed
        // value is returned to the caller so the consumer can use it
        // directly instead of re-parsing the raw string at await time.
        return try Self.parseScheduleInterval(waitTimeout)
    }

    /// For local-file attachment paths, verify the file exists, is
    /// a regular file (not a directory, FIFO, etc.), and is not a
    /// symbolic link. Remote (`http`/`https`) URLs are rejected
    /// outright at validation with a "use curl to pre-download"
    /// message — `--attachment` does not fetch over the network.
    ///
    /// Routes through `classifyAttachment` so the validator and
    /// `makeAttachment` agree on which bucket the input falls into.
    /// Previously two separate classifiers diverged on
    /// `file:relative/path` (no slashes) — the validator skipped the
    /// existence check and `makeAttachment` produced an opaque
    /// "couldn't be opened" error.
    ///
    /// Symlink rejection is the send-time half of the defence
    /// against the TOCTOU + symlink hazard: without it, a path like
    /// `/tmp/foo.png` pointing at `~/.ssh/id_rsa` would pass
    /// validation and have its target copied into the per-app UN
    /// attachment store. The race window between this check and
    /// `UNNotificationAttachment.init`'s open is closed (as well as
    /// is possible from Swift) by `rejectIfUnsafeForAttachment` in
    /// `makeAttachment`.
    ///
    /// Extracted as `static` so tests can drive it without setting up
    /// the full `Send` flow.
    ///
    /// - Parameter path: The user-supplied `--attachment` value.
    /// - Throws: `ValidationError` if the value is an http/https URL
    ///   (pointing the user at `curl`), or if the path resolves to a
    ///   local filesystem location that does not exist, is a symlink,
    ///   or is not a regular file.
    static func validateAttachmentExistsIfLocal(_ path: String) throws {
        switch classifyAttachment(path) {
        case .rejectedRemoteURL(let scheme):
            // The remote-fetch path was removed. Tell the user how to
            // turn this into a supported invocation instead of letting
            // them rediscover the deletion through an opaque downstream
            // failure.
            throw ValidationError(
                "--attachment '\(path)': URL scheme '\(scheme)' is not supported. "
                + "--attachment accepts local paths only. Pre-download with "
                + "`curl -o /tmp/file '\(path)'` (or wget) and pass the "
                + "resulting path."
            )
        case .otherScheme:
            // Other-scheme — `makeAttachment` produces a friendlier
            // "disallowed scheme" error than we could here.
            return
        case .localPath(let resolved):
            // Foundation's `URL.path` percent-decodes printable
            // control-character escapes (`%0A`, `%0D`, `%09`) when
            // the input was a `file:` URL. The raw `path` was
            // already screened by `validateAttachmentPath` above,
            // but the screen ran on the encoded form — `%0A` is
            // three printable ASCII bytes there. Re-screen the
            // decoded path here so a `file:///tmp/x%0Ay.png`
            // doesn't reach `lstat` with an embedded LF byte.
            do {
                try Send.rejectControlCharactersInDecodedPath(resolved)
            } catch let error as ValidationError {
                throw ValidationError(
                    "--attachment '\(path)': \(error)"
                )
            }
            do {
                try rejectIfUnsafeForAttachment(path: resolved)
            } catch let error as AttachmentError {
                // Translate the AttachmentError into a ValidationError
                // so ArgumentParser exits with EX_USAGE and the
                // diagnostic is formatted alongside other --option
                // failures. Carry the original input string in the
                // user-facing text so the user sees what they typed,
                // not the percent-decoded `file:` path.
                throw ValidationError(
                    "--attachment '\(path)': \(error.description)"
                )
            }
        }
    }

    /// Pre-flight validation for `--attachment`. Catches three failure
    /// modes that would otherwise produce confusing downstream errors:
    ///
    /// 1. Empty string — `URL(fileURLWithPath: "")` resolves to the cwd
    ///    and the attachment init fails with an opaque message.
    /// 2. `~user/foo` — `NSString.expandingTildeInPath` only expands the
    ///    current user's tilde; `~someone/foo` falls through to a
    ///    "file not found" later in the pipeline.
    /// 3. `file://hostname/foo` — Foundation parses `hostname` as the
    ///    URL host and never reaches the filesystem. Local file URLs
    ///    must use `file:///foo` (three slashes, empty host).
    ///
    /// Extracted as `static` so tests can exercise the rules directly.
    ///
    /// - Parameter path: The user-supplied `--attachment` value.
    /// - Throws: `ValidationError` on any of the above conditions.
    static func validateAttachmentPath(_ path: String) throws {
        guard !path.isEmpty else {
            throw ValidationError("--attachment cannot be empty.")
        }
        // Screen NUL and other control characters. The path feeds
        // `lstat`/`realpath`/`readlink` via C-string bridges that
        // truncate at the first NUL — a value like
        // `"/tmp/safe.png\0/etc/passwd"` would otherwise probe
        // `/tmp/safe.png` and silently attach an attacker-controllable
        // location. Mirrors the screening on `--identifier`,
        // `--thread-id`, and `--sound`. The error message mentions the
        // flag explicitly so the diagnostic is consistent with the
        // other sites.
        if path.rangeOfCharacter(from: .controlCharacters) != nil {
            throw ValidationError(
                "--attachment cannot contain control characters (NUL, newlines, "
                + "tabs, etc.). NUL truncates downstream filesystem calls."
            )
        }
        if path.hasPrefix("~"), path != "~", !path.hasPrefix("~/") {
            throw ValidationError(
                "--attachment '\(path)' uses ~user/ syntax which is not supported. "
                + "Use an absolute path or a current-user-relative path (~/...)."
            )
        }
        // Detect file URLs by scheme, not by literal `file://` prefix:
        // `FILE://server/share` would otherwise bypass the host check
        // because the prefix match is case-sensitive, then fail with a
        // confusing "no such file" downstream in `makeAttachment`'s
        // relative-path branch. Using `URL(string:).scheme` matches all
        // case variants and also covers the rare `file:/foo` form.
        //
        // POSIX-locale lowercasing: this is a security-relevant
        // deny-list comparison (a `file://` URL with a host
        // component bypasses the user's mental model of "local
        // file") and the default `String.lowercased()` is
        // locale-aware. Under `LANG=tr_TR.UTF-8`,
        // `"FILE".lowercased()` is "fıle" (dotless i) and would
        // not match the ASCII `"file"` literal — letting a
        // Turkish-locale process slip an uppercase `FILE://host/x`
        // past the host check.
        if let parsed = URL(string: path),
           parsed.scheme?.lowercased(with: Locale(identifier: "en_US_POSIX")) == "file",
           let host = parsed.host, !host.isEmpty {
            throw ValidationError(
                "--attachment '\(path)' uses file:// with a host component ('\(host)'). "
                + "Use file:///path (three slashes, no host) for local files."
            )
        }
        // Catch URL-shaped local paths the classifier would otherwise
        // route to `.localPath`. A value like `https:/notes.png`
        // (single slash, no authority) parses with scheme `https`
        // but no host, so it isn't `.rejectedRemoteURL` —
        // `classifyAttachment` falls through to `.localPath("https:/notes.png")`
        // and hands the raw string to `lstat`. The user almost
        // certainly meant a URL and miss-typed; surface a clear
        // diagnostic up front rather than the opaque "no such file"
        // downstream. The classifier itself doesn't change shape
        // (`release:v1.png` still goes through), only the remote
        // scheme alternations are caught here.
        let remoteSchemeMissingAuthority: Set<String> = ["http", "https", "ftp"]
        if let parsed = URL(string: path),
           let scheme = parsed.scheme?.lowercased(with: Locale(identifier: "en_US_POSIX")),
           remoteSchemeMissingAuthority.contains(scheme),
           !path.contains("://") {
            throw ValidationError(
                "--attachment '\(path)' looks like a malformed URL "
                + "(scheme '\(scheme)' with a single slash). Did you mean "
                + "'\(scheme)://...'? Note that --attachment accepts local "
                + "paths only; pre-download remote content with `curl -o /tmp/file URL` "
                + "and pass the resulting path."
            )
        }
    }

    /// Standard system sound directories scanned by `validateSoundName`.
    /// `~/Library/Sounds` is *not* included: the UserNotifications
    /// framework doesn't resolve names from a user's home, so including
    /// it would produce false positives (validation passes but playback
    /// is silent).
    static let defaultSoundDirectories: [String] = [
        "/System/Library/Sounds",
        "/Library/Sounds"
    ]

    /// File extensions tried when probing for a sound file. Restricted
    /// to the two formats the UserNotifications framework actually
    /// resolves for system sounds by name — `.wav` / `.m4a` files in
    /// `/Library/Sounds` exist on disk but play silently when named
    /// without an extension via `UNNotificationSound(named:)`, so we
    /// don't validate against extensions that would lie.
    static let defaultSoundExtensions: [String] = ["aiff", "caf"]

    /// Pure-function counterpart to `validateSoundIfPresent`. Extracted
    /// so tests can inject a temp directory and exercise the path-syntax
    /// and existence rules without depending on the host's sound files.
    ///
    /// - Parameters:
    ///   - sound: The user-supplied `--sound` value.
    ///   - directories: Filesystem directories to scan. Defaults to the
    ///     standard system sound locations.
    ///   - extensions: File extensions to try. Defaults to the standard
    ///     UN-framework set.
    /// - Throws: `ValidationError` if `sound` contains path syntax, or
    ///   if it does not correspond to a file in any of `directories`.
    static func validateSoundName(
        _ sound: String,
        directories: [String] = defaultSoundDirectories,
        extensions: [String] = defaultSoundExtensions
    ) throws {
        guard sound != "default" else { return }
        // Reject names with path separators, backslashes, control
        // characters (including NUL), or a leading `.`.
        // `appendingPathComponent` does no sanitisation, so a value like
        // "../../etc/passwd" would otherwise probe arbitrary filesystem
        // locations. A NUL byte is especially dangerous because the C
        // bridge for `fileExists(atPath:)` truncates at NUL — so a name
        // like "Glass\0/etc/passwd" could probe an attacker-controlled
        // path under the truncated prefix.
        let forbidden = CharacterSet(charactersIn: "/\\")
            .union(CharacterSet.controlCharacters)
        guard sound.rangeOfCharacter(from: forbidden) == nil,
              !sound.hasPrefix(".") else {
            throw ValidationError(
                "Sound '\(sound)' must be a plain name (no path separators or control characters). "
                + "Example: --sound Glass."
            )
        }
        let fm = FileManager.default
        for dir in directories {
            let dirURL = URL(filePath: dir, directoryHint: .isDirectory)
            for ext in extensions {
                let candidate = dirURL.appendingPathComponent("\(sound).\(ext)").path
                if fm.fileExists(atPath: candidate) { return }
            }
        }
        let locations = directories.joined(separator: " or ")
        throw ValidationError(
            "Sound '\(sound)' was not found in \(locations). "
            + "Use 'default' for the default notification sound."
        )
    }

    /// Maximum byte size for the property-list serialization of
    /// `content.userInfo`. UN's documented limit is "system defined"
    /// and a practical hard cap is documented at 4 KB for APNs payloads
    /// (a much stricter regime). For local UN posts on macOS the limit
    /// is far more permissive, but a runaway `--exec` string can still
    /// pathologically inflate userInfo, and oversized requests fail
    /// inside `add(_:)` with an opaque NSCocoaError that is harder to
    /// debug than a clean pre-flight rejection. 16 KB is well over the
    /// realistic ceiling for what roar writes (longest field is
    /// `--exec`, capped here at ~16 KB) while still tripping on
    /// pathological inputs that would otherwise hand-roll a denial of
    /// service against `usernoted`.
    static let maximumUserInfoSize = 16 * 1024

    /// Reject a `userInfo` dict whose property-list serialization
    /// exceeds `maximumUserInfoSize`. The serialization shape we
    /// measure is `binary` because that's what UN's XPC bridge uses
    /// internally — measuring under `xml` would overestimate by
    /// 2–5× and reject inputs `add(_:)` would actually accept.
    ///
    /// `nonisolated static` so tests can pin the rule without
    /// constructing a full `Send` invocation. The function is total
    /// over `[String: String]` because every value type roar puts
    /// into userInfo is a `String` (so property-list serialization
    /// cannot fail with a type error); if a future build adds
    /// non-string values, the `throws` from `PropertyListSerialization`
    /// surfaces via the catch arm as a clean ValidationError.
    ///
    /// - Parameter userInfo: The dictionary roar built up from the
    ///   user's `--exec` / `--open-url` / `--activate-bundle-id`
    ///   flags.
    /// - Throws: `ValidationError` if the serialized size exceeds
    ///   `maximumUserInfoSize`, or if serialization itself fails.
    static func validateUserInfoSize(_ userInfo: [String: String]) throws {
        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: userInfo,
                format: .binary,
                options: 0
            )
        } catch {
            throw ValidationError(
                "Failed to measure notification userInfo size: "
                + "\(error.localizedDescription)"
            )
        }
        guard data.count <= maximumUserInfoSize else {
            throw ValidationError(
                "Notification userInfo (built from --exec / --open-url / "
                + "--activate-bundle-id) is \(data.count) bytes; the "
                + "per-notification limit is \(maximumUserInfoSize) bytes. "
                + "Shorten the offending value before re-sending."
            )
        }
    }
}
