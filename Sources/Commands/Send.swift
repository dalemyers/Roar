import AppKit
import ArgumentParser
import Darwin
import Foundation
import UserNotifications

/// `roar send` — post a single notification.
///
/// This file defines the `Send` command struct, its ArgumentParser
/// `@Option`/`@Flag` declarations, and the `run()` orchestrator.
/// Helper logic (validation, schedule parsing, action parsing,
/// authorization, etc.) lives in `Send+*.swift` extension files —
/// see each file's top-of-file comment for the seam.
struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Post a notification."
    )

    // Attachment constants and helpers live in SendAttachment.swift.

    @Option(
        name: .long,
        help: "The notification title. Defaults to the machine's user-visible name (System Settings → General → About → Name), falling back to the short hostname."
    )
    var title: String?

    @Option(name: .long, help: "The notification subtitle.")
    var subtitle: String?

    @Option(
        name: [.long, .customShort("b")],
        help: "The notification body. Read from stdin if omitted and stdin is piped."
    )
    var body: String?

    @Option(
        name: .long,
        help: "Name of a system sound to play, or 'default' for the default notification sound."
    )
    var sound: String?

    @Option(
        name: .long,
        help: "Stable identifier for this notification request. Reposting with the same identifier REPLACES the prior notification in place — no flicker, no duplicate in Notification Center, no second sound. Omit the flag to let roar mint a fresh UUID per send (every invocation creates a new notification). Pass an identifier when you want a notification to update (build progress, status pings, transient state) rather than accumulate."
    )
    var identifier: String?

    @Option(
        name: .long,
        help: "Bundle identifier of an application to activate when the notification is clicked."
    )
    var activateBundleID: String?

    @Option(
        name: .long,
        help: "URL to open when the notification is clicked. By default only http, https, and mailto are accepted. To open URLs in other schemes (e.g. x-myapp://, vscode://) add them one at a time with --allow-url-scheme. There is no 'accept everything' override — schemes like javascript:, data:, file:, applescript:, afp:, smb: must be enabled explicitly and only if you understand the click-time risk."
    )
    var openURL: String?

    @Option(
        name: .long,
        help: "Shell command to run via /bin/sh -c when the notification is clicked. Requires --allow-shell-on-click."
    )
    var exec: String?

    @Flag(
        name: .long,
        help: "Acknowledge that --exec runs a shell command on click and proceed. Required when --exec is set."
    )
    var allowShellOnClick: Bool = false

    @Option(
        name: .long,
        parsing: .singleValue,
        help: "Add a URL scheme to the --open-url allow-list. Repeat for each scheme (--allow-url-scheme vscode --allow-url-scheme slack). The default allow-list (http, https, mailto) is always included. Some schemes carry significant risk on click (javascript: and data: run script; file:, afp:, smb: hand attacker-controlled paths to LaunchServices / Finder; applescript: and help: have a long history of RCEs) — only add schemes whose click-time behaviour you've verified."
    )
    var allowUrlScheme: [String] = []

    @Option(
        name: .long,
        parsing: .singleValue,
        help: "Local path to an image, audio file, or video to attach to the notification. Local path only — `--attachment` does not fetch URLs; pre-download remote content with `curl -o /tmp/file URL` (or wget) and pass the resulting path. Repeat the flag for multiple attachments (--attachment a.png --attachment b.png); the system caps the visible count per notification but extras still ride along in the post."
    )
    var attachment: [String] = []

    @Flag(
        name: .long,
        help: "Suppress the small thumbnail preview that macOS renders alongside the attachment in Notification Center."
    )
    var noThumbnail: Bool = false

    @Option(
        name: .long,
        help: "Seconds offset into a video attachment to use for thumbnail generation. Ignored for image attachments. Must be >= 0."
    )
    var thumbnailTime: Double?

    @Option(
        name: .long,
        help: "How disruptive the notification should be. 'passive' shows in Notification Center without a banner; 'active' (default) is the standard banner+NC behaviour; 'time-sensitive' bypasses Focus / Do Not Disturb."
    )
    var interruptionLevel: InterruptionLevel?

    @Option(
        name: .long,
        help: "Thread identifier for grouping related notifications in Notification Center. Notifications with the same thread identifier appear together."
    )
    var threadID: String?

    @Option(
        name: .long,
        help: "Importance hint between 0.0 and 1.0 used by macOS to rank this notification within Notification Center summaries (higher = more prominent)."
    )
    var relevanceScore: Double?

    @Option(
        name: .customLong("in"),
        help: "Schedule the notification to fire after the given duration. Format: <number><unit> where unit is s|m|h|d (e.g. 30s, 5m, 2h, 1d). Mutually exclusive with --at."
    )
    var scheduleIn: String?

    @Option(
        name: .customLong("at"),
        help: "Schedule the notification to fire at a specific time. Accepted forms: ISO 8601 with zone ('2026-12-31T17:00:00Z', '2026-12-31T17:00:00+01:00'); local time without zone ('2026-12-31T17:00:00', '2026-12-31 17:00:00', '2026-12-31 17:00'); or date-only at local midnight ('2026-12-31'). Past timestamps are rejected. Mutually exclusive with --in."
    )
    var scheduleAt: String?

    @Option(
        name: .customLong("repeat"),
        help: "Schedule the notification to fire on a recurring calendar pattern. Accepted forms: 'hourly' (top of every hour); 'daily:HH:MM' (every day at HH:MM, 24-hour); 'weekly:DAY:HH:MM' (every week on DAY ∈ mon|tue|wed|thu|fri|sat|sun at HH:MM); 'monthly:D:HH:MM' (every month on day D ∈ 1..31 at HH:MM). Times are interpreted in the system's current local time zone. Note: for D ∈ 29..31, months that lack that day do NOT skip — the notification fires on the 1st of the following month instead (e.g. monthly:31 in a 30-day month fires on the 1st). This is the macOS UserNotifications framework's behavior and cannot be changed for a repeating trigger. Use D ≤ 28 if you need it to land on the same day every month. Mutually exclusive with --in and --at."
    )
    var scheduleRepeat: String?

    @Option(
        name: .long,
        parsing: .singleValue,
        help: "Add a custom button to the notification, in the form 'id:title' (e.g. --action approve:Approve --action reject:Reject), optionally with action flags after a '::' separator (e.g. --action 'delete:Delete::destructive' or 'confirm:Confirm::auth-required,destructive'). Supported flags: 'destructive' (red title) and 'auth-required' (user must unlock the device). The UN '.foreground' option is deliberately NOT exposed — roar is an LSUIElement bundle with no window to bring forward, so it would do nothing. Requires --wait — the id is what gets printed to stdout when the button is clicked. Repeat for additional buttons (max 4)."
    )
    var action: [String] = []

    @Option(
        name: .long,
        parsing: .singleValue,
        help: "Add a text-input action (reply-style) to the notification. Same id:title[::flags] syntax as --action. At most one --text-action per notification. Requires --wait — the typed text is printed to stdout on the line after the action id. Customise the inline button label with --text-button-title and the placeholder text with --text-placeholder."
    )
    var textAction: [String] = []

    @Option(
        name: .long,
        help: "Placeholder text shown inside the reply field for --text-action. Defaults to empty. No effect without --text-action."
    )
    var textPlaceholder: String?

    @Option(
        name: .long,
        help: "Label of the inline 'send' button next to the reply field for --text-action. Defaults to the system value (typically 'Send'). No effect without --text-action."
    )
    var textButtonTitle: String?

    @Option(
        name: .long,
        help: "Hint string handed to the target app on click, used to route the click to a specific window or document. Same length and character constraints as --identifier."
    )
    var targetContentID: String?

    @Option(
        name: .long,
        help: "Placeholder body shown when the user has set 'Show Previews' to 'When Unlocked' or 'Never' in System Settings → Notifications → Roar. Lets sensitive content (auth codes, private messages) post safely without leaking on the lock screen. Plumbed into the notification category's hiddenPreviewsBodyPlaceholder."
    )
    var hidePreviewsBodyPlaceholder: String?

    @Option(
        name: .long,
        help: "Format string for the summary line macOS renders when multiple notifications in this category collapse together in Notification Center. Supports the framework's tokens: %u for the unread count and %@ for a comma-joined list of intent identifiers. Plumbed into the notification category's categorySummaryFormat."
    )
    var summaryFormat: String?

    @Flag(
        name: .long,
        help: "Show the notification title on the lock screen / Notification Center even when the user has set 'Show Previews' to 'When Unlocked' or 'Never'. Maps to the UNNotificationCategoryOptions.hiddenPreviewsShowTitle category option. Without this flag, macOS replaces the title with the bundle name when previews are hidden."
    )
    var showTitleWhenPreviewsHidden: Bool = false

    @Flag(
        name: .long,
        help: "Show the notification subtitle on the lock screen / Notification Center even when the user has set 'Show Previews' to 'When Unlocked' or 'Never'. Maps to the UNNotificationCategoryOptions.hiddenPreviewsShowSubtitle category option. Without this flag, macOS suppresses the subtitle when previews are hidden."
    )
    var showSubtitleWhenPreviewsHidden: Bool = false

    @Option(
        name: .long,
        help: "UTI (e.g. public.png, public.mpeg-4, public.jpeg) telling the UserNotifications framework how to interpret the attachment. Use when the file's extension is misleading or absent — the framework otherwise falls back to extension-based detection. Plumbed into the attachment's UNNotificationAttachmentOptionsTypeHintKey. Applies uniformly to every --attachment in this invocation."
    )
    var attachmentTypeHint: String?

    @Option(
        name: .long,
        parsing: .singleValue,
        help: "How the notification should appear if it arrives while roar itself is still running in the foreground (typically only the --wait flow). Repeat the flag for multiple options (--foreground-presentation banner --foreground-presentation list), choosing from: banner, list, sound. To suppress attention-grabbing presentation entirely, use --interruption-level passive — the literal value 'none' is rejected because an invisible-but-clickable notification surface is a phishing vector. When omitted, roar uses banner+list+sound. No effect on notifications delivered after roar has already exited — those go through the system's default presentation."
    )
    var foregroundPresentation: [String] = []

    @Option(
        name: .long,
        help: "Focus-filter hint string handed to the framework via UNMutableNotificationContent.filterCriteria. Used by Focus filters to decide whether a notification breaks through the user's current Focus mode (e.g. a conversation identifier in a chat app). Free-form string; the framework does not validate the value."
    )
    var filterCriteria: String?

    @Flag(
        name: .long,
        help: "Block until the user interacts with the notification, then print the chosen action id to stdout and exit. Prints 'default' if the body itself was clicked (exit 0), 'dismiss' if explicitly dismissed (exit 3 — distinct so scripts can branch on $? without parsing stdout), or a custom action id (exit 0). For a --text-action interaction, prints the typed text on the line after the action id (the typed text may contain newlines and arbitrary bytes — read to EOF rather than line-by-line). Mutually exclusive with --exec, --open-url, and --activate-bundle-id (the calling script handles side effects based on the printed id)."
    )
    var wait: Bool = false

    @Option(
        name: .long,
        help: "Maximum time to wait for interaction in --wait mode. Same format as --in (e.g. 30s, 5m). Defaults to 5m when --wait is set so unattended scripts can't hang forever; pass a larger value (max 365d) to extend. On timeout 'timeout' is printed to stdout and the process exits with code 2."
    )
    var waitTimeout: String?

    @OptionGroup var output: OutputOptions

    /// JSON shape for `roar send --json` on the non-wait happy path.
    /// `identifier` is what the user passed via `--identifier`, or the
    /// UUID we minted if they didn't — useful for the caller to
    /// follow up with `roar dismiss <identifier>` or
    /// `--identifier <identifier>` on a replace-in-place repost.
    struct JSONPostedShape: Encodable, Equatable {
        let identifier: String
        let posted: Bool
    }

    /// User-facing names for `UNNotificationInterruptionLevel`. `.critical`
    /// is intentionally absent: it requires Apple-granted entitlement and
    /// has no legitimate use case for an ad-hoc-signed CLI tool.
    enum InterruptionLevel: String, CaseIterable, ExpressibleByArgument {
        case passive
        case active
        case timeSensitive = "time-sensitive"

        var unValue: UNNotificationInterruptionLevel {
            switch self {
            case .passive: return .passive
            case .active: return .active
            case .timeSensitive: return .timeSensitive
            }
        }
    }

    /// Backwards-compatible aliases for the centralised
    /// `CommandExit` types. Lets call sites in `Send+Wait.swift`
    /// and the legacy test surface keep saying `Send.ExitPlan(...)`
    /// / `Send.exitHook = …` while the underlying storage lives
    /// once in `CommandExit`. The chokepoint discipline (one drain
    /// rule, one `Darwin.exit`, one test seam to clear) is in
    /// `CommandExit.perform`; see that file for the full
    /// rationale.
    typealias ExitPlan = CommandExit.Plan

    /// Forwarding accessor for the shared test seam. Reads / writes
    /// `CommandExit.hook`. Three command surfaces (`send`, `clear`,
    /// `dismiss`) share one underlying hook so a `tearDown` that
    /// clears it once is sufficient — the previous per-command
    /// hooks could leak across files because each file's
    /// `tearDown` cleared only its own name.
    static var exitHook: (@Sendable (CommandExit.Plan) async -> Void)? {
        get { CommandExit.hook }
        set { CommandExit.hook = newValue }
    }

    /// Forwarding helper. Pulled out so every terminal branch in
    /// `Send.run` flows through one routine — a future drain or
    /// exit-code change cannot accidentally bypass the hook.
    /// Implementation lives in `CommandExit.perform`.
    static func performExit(_ plan: CommandExit.Plan) async {
        await CommandExit.perform(plan)
    }

    /// Run the send.
    ///
    /// On success the process is terminated via `exit(0)` immediately
    /// after `add(_:)` returns — the request has been handed off via
    /// XPC to `usernoted` at that point, so this process is no longer
    /// involved in delivery. On validation failure throws so
    /// ArgumentParser prints usage and exits non-zero.
    ///
    /// - Throws: `ValidationError` for user-input problems;
    ///   `URLValidation.Error` for malformed `--open-url`; whatever
    ///   `UNUserNotificationCenter` throws from `requestAuthorization`
    ///   or `add(_:)`.
    func run() async throws {
        // Validate flags before draining stdin: a piped 1 MB body
        // shouldn't be read into memory only to be discarded by a
        // missing --allow-shell-on-click. Pure-syntax checks run first
        // (including building the flag-derived userInfo dict and
        // pinning its serialized size against the per-request cap),
        // then the stdin read, then the authorization handshake.
        // Validate the `--allow-url-scheme` syntax even when
        // `--open-url` is absent so a typo'd scheme name surfaces
        // through ArgumentParser rather than sitting silently in the
        // parsed command struct.
        try Self.validateAllowUrlSchemeNames(allowUrlScheme)
        let resolvedOpen = try validateOpenURLIfPresent()
        let resolvedOpenURL = resolvedOpen?.absoluteString
        let resolvedOpenUrlAllowList = resolvedOpen?.allowList
        try validateExecOptIn()
        // Capture the trimmed values so they thread into the downstream
        // sinks (userInfo, content.*Identifier, content.filterCriteria,
        // requestIdentifier). Without binding, `--thread-id ' foo '`
        // would validate cleanly but the un-trimmed property would
        // land in the XPC payload — UN groups / replaces / dismisses
        // by exact-string match, so the trailing whitespace silently
        // diverges from any later command that uses the clean id.
        // See `SharedValidation.requireNonBlank`'s docstring for the
        // class of bug this prevents.
        let resolvedActivateBundleID = try validateActivateBundleIDIfPresent()
        try validateSoundIfPresent()
        try validateAttachmentIfPresent()
        let resolvedThreadID = try validateThreadIDIfPresent()
        try validateRelevanceScoreIfPresent()
        let resolvedIdentifier = try Self.validateRequestIdentifier(identifier)
        let resolvedTargetContentID = try Self.validateRequestIdentifier(
            targetContentID, flagName: "--target-content-id")
        let resolvedTitle = title ?? Self.defaultTitle()
        try Self.validateTitle(resolvedTitle)
        try Self.validateSubtitle(subtitle)
        let resolvedFilterCriteria = try Self.validateFilterCriteria(filterCriteria)
        let resolvedAttachmentTypeHint = try Self.validateAttachmentTypeHint(
            attachmentTypeHint,
            attachments: attachment
        )
        let resolvedForegroundPresentation =
            try Self.parseForegroundPresentationOptions(foregroundPresentation)
        let resolvedTrigger = try resolveScheduleTrigger()
        try Self.validateTextSideOptions(
            textActions: textAction,
            textPlaceholder: textPlaceholder,
            textButtonTitle: textButtonTitle
        )
        let parsedActions = try Self.parseActions(action)
        let parsedTextActions = try Self.parseTextActions(
            textAction,
            placeholder: textPlaceholder ?? "",
            // UN treats an empty `textInputButtonTitle` as "use the
            // system default" (typically "Send") on macOS. We pass
            // `""` rather than substituting a hard-coded "Send" so the
            // system can localise per the user's preferred language.
            buttonTitle: textButtonTitle ?? ""
        )
        try Self.validateActionIDUniqueness(
            buttons: parsedActions, textInputs: parsedTextActions)
        let allActions = parsedActions + parsedTextActions
        try Self.validateActionWaitCompatibility(
            actionsCount: allActions.count,
            wait: wait,
            exec: exec,
            openURL: openURL,
            activateBundleID: activateBundleID
        )
        let resolvedWaitTimeout = try Self.validateWaitTimeout(
            waitTimeout: waitTimeout, wait: wait)

        // Build `userInfo` and its size check *before* draining stdin.
        // The dictionary depends only on flag values (--exec,
        // --open-url, --activate-bundle-id, --foreground-presentation)
        // — none of these need the resolved body or the resolved
        // attachments — so a too-large payload should fail fast,
        // without first reading up to 1 MB from a pipe that the user
        // produced. The header comment at the top of `run()` promises
        // pure-syntax checks run before the stdin drain; userInfo
        // sizing belongs in that bucket. The dictionary is stored on
        // `content` later, after the body / attachments are known.
        let userInfo = Self.buildUserInfo(
            activateBundleID: resolvedActivateBundleID,
            exec: exec,
            resolvedOpenURL: resolvedOpenURL,
            openUrlAllowList: resolvedOpenUrlAllowList,
            resolvedForegroundPresentation: resolvedForegroundPresentation
        )
        try Self.validateUserInfoSize(userInfo)

        let resolvedBody = try resolveBody()
        // Bound the body size at the same 4 KB ceiling as title /
        // subtitle. `resolveBody` enforces a 1 MB stdin-read cap, but
        // the argument-form path (`--body "$REMOTE_DATA"` from a
        // shell) bypasses that read cap entirely; this catches both
        // shapes uniformly.
        try Self.validateResolvedBodySize(resolvedBody)

        let center = UNUserNotificationCenter.current()
        try await ensureAuthorized(center: center)

        // `.provisional` notifications are documented as "delivered
        // quietly to Notification Center without sound, without a
        // banner, and without breaking through Focus."  Several
        // attention-grabbing affordances are therefore silently
        // downgraded — emit a one-time stderr warning so the silence
        // isn't mysterious. Promotion to full auth happens when the
        // user interacts with the first provisional notification
        // ("Keep" affordance) or flips the switch in System Settings.
        //
        // The check runs only when the user supplied at least one
        // affordance that would be downgraded; this avoids a
        // settings round-trip on the hot path for plain `roar send`
        // invocations.
        let silencedUnderProvisional = Self.affordancesDowngradedByProvisional(
            sound: sound,
            interruptionLevel: interruptionLevel
        )
        if !silencedUnderProvisional.isEmpty {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .provisional {
                let list = silencedUnderProvisional.joined(separator: ", ")
                let warning = "warning: \(list) set but Roar is only "
                    + "provisionally authorized; macOS will deliver this "
                    + "notification quietly. Tap 'Keep' on the first "
                    + "notification (or enable banners in System Settings → "
                    + "Notifications → Roar) to promote.\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
        }

        let content = UNMutableNotificationContent()
        content.title = resolvedTitle
        if let subtitle { content.subtitle = subtitle }
        content.body = resolvedBody
        if let interruptionLevel { content.interruptionLevel = interruptionLevel.unValue }
        if let resolvedThreadID { content.threadIdentifier = resolvedThreadID }
        if let relevanceScore { content.relevanceScore = relevanceScore }
        if let resolvedTargetContentID { content.targetContentIdentifier = resolvedTargetContentID }
        if let resolvedFilterCriteria { content.filterCriteria = resolvedFilterCriteria }

        // `userInfo` was built and size-checked above the stdin drain;
        // attach it now that `content` exists.
        content.userInfo = userInfo

        if let sound {
            content.sound = (sound == "default")
                ? .default
                : UNNotificationSound(named: UNNotificationSoundName(sound))
        }

        // Register the dynamic category and stamp the content with its
        // identifier *before* `add(_:)` so usernoted has the action
        // metadata in hand by the time it renders the banner. The XPC
        // pipe preserves ordering for same-connection messages, so
        // shipping `setNotificationCategories` first guarantees the
        // category is known when `add` arrives.
        //
        // We union with the existing category set rather than replacing
        // it so a previously-delivered notification (still in NC) keeps
        // its buttons if its category was registered by an earlier
        // invocation that's already exited. The union is racy across
        // concurrent `roar send` invocations — last setter wins, prior
        // additions may be lost — but concurrent CLI invocations are
        // rare and the worst outcome is a missing button on a previous
        // notification, not a crash or data loss.
        if let category = Self.buildCategory(
            for: allActions,
            dismissableEvenIfEmpty: wait,
            hiddenPreviewsBodyPlaceholder: hidePreviewsBodyPlaceholder,
            categorySummaryFormat: summaryFormat,
            extraCategoryOptions: Self.buildHiddenPreviewsCategoryOptions(
                showTitle: showTitleWhenPreviewsHidden,
                showSubtitle: showSubtitleWhenPreviewsHidden
            )
        ) {
            let existing = await center.notificationCategories()
            var merged = existing
            merged.insert(category)
            center.setNotificationCategories(merged)
            content.categoryIdentifier = category.identifier
        }

        // Decide the request identifier up-front so the `--wait`
        // subscription can scope itself to this specific request.
        // Reposting with the same identifier means UN replaces the
        // prior notification on `add(_:)`, so no explicit pre-remove
        // is needed; with no `--identifier`, a fresh UUID gives every
        // notification its own slot.
        let requestIdentifier = resolvedIdentifier ?? UUID().uuidString

        // If `--wait` is set, install the response subscription on
        // the shared app delegate *before* `add(_:)` so a near-instant
        // click (cached banner state, accessibility automation) cannot
        // race the subscription. The delegate buffers the response if
        // it arrives before `awaitNextResponse` is awaited.
        let delegateForWait: RoarAppDelegate?
        if wait {
            // The runtime delegate is installed by `main.swift` before
            // ArgumentParser runs. If it isn't a `RoarAppDelegate`
            // (some future XPC-loaded harness, a test that subclasses
            // the delegate, etc.) surface a clear error rather than
            // trapping — a typed error here is strictly better than
            // a force-cast crash.
            // `NSApplication.shared` is `@MainActor`-isolated in modern
            // SDKs, so the lookup hops onto the main actor explicitly.
            let resolved: RoarAppDelegate? = await MainActor.run {
                guard let delegate = NSApplication.shared.delegate as? RoarAppDelegate else {
                    return nil
                }
                delegate.enableWaitMode(forRequest: requestIdentifier)
                return delegate
            }
            guard let resolved else {
                throw ValidationError(
                    "--wait requires roar's app delegate to be installed; "
                    + "this build appears to be running in an unsupported host."
                )
            }
            delegateForWait = resolved
        } else {
            delegateForWait = nil
        }

        if !attachment.isEmpty {
            // `--thumbnail-time` / `--no-thumbnail` apply uniformly to
            // every `--attachment` — the framework lets each
            // attachment carry its own options dict, but the CLI
            // surface keeps the per-flag option *singular* (one
            // `--thumbnail-time` value) so the meaning stays
            // predictable when readers scan the invocation. Users who
            // need per-attachment options can break the post into
            // separate `roar send` invocations.
            let attachmentOptions = Self.buildAttachmentOptions(
                noThumbnail: noThumbnail,
                thumbnailTime: thumbnailTime,
                typeHint: resolvedAttachmentTypeHint
            )
            var built: [UNNotificationAttachment] = []
            built.reserveCapacity(attachment.count)
            for path in attachment {
                do {
                    let un = try await makeAttachment(
                        from: path,
                        options: attachmentOptions
                    )
                    built.append(un)
                } catch {
                    throw AttachmentFetchError(path: path, underlying: error)
                }
            }
            content.attachments = built
        }

        let request = UNNotificationRequest(
            identifier: requestIdentifier,
            content: content,
            trigger: resolvedTrigger
        )
        // `enableWaitMode` was already called above (before `add`) so
        // a near-instant click cannot race the subscription. If
        // `add(_:)` throws (oversized payload UN didn't surface
        // earlier, transient framework error, auth flipped after
        // `ensureAuthorized` returned), the wait subscription is
        // stranded on the shared delegate: `waitIdentifier` stays
        // set, `awaitNextResponse` would park forever. In production
        // the process exits via ArgumentParser's error formatter, so
        // the leak is bounded by process lifetime — but a test
        // driver, future XPC mode, or any caller that catches the
        // throw and continues would inherit stale wait state. Clear
        // it on the failure path before re-throwing so the delegate
        // is left in the same shape as if `enableWaitMode` had never
        // been called.
        do {
            try await center.add(request)
        } catch {
            if let delegateForWait {
                await MainActor.run { delegateForWait.cancelWait() }
            }
            throw error
        }

        // `add(_:)` returning successfully means UN has copied the file
        // into its own store and the request has been handed off via XPC
        // to `usernoted`. For the immediate-exit (non-wait) path this
        // makes the process irrelevant to delivery and we can terminate
        // straight away. For `--wait`, the framework will dispatch the
        // user's click back into this *same* process via the delegate
        // we registered, so we have to keep the runloop alive until
        // `awaitNextResponse` returns.
        if let delegateForWait {
            let response = await Self.awaitResponseWithOptionalTimeout(
                delegate: delegateForWait,
                timeoutSeconds: resolvedWaitTimeout
            )
            // Extract the primitives the wait-exit branch needs and
            // hand them to the helper. `UNNotificationResponse` is
            // sealed (no public initialiser), so the helper takes
            // primitives the tests can construct — same pattern as
            // `formatWaitResponse`. `nil` means the timeout path.
            let primitives: WaitExitPrimitives? = response.map {
                WaitExitPrimitives(
                    actionIdentifier: Self.printableActionID(from: $0),
                    userText: Self.textInputResponseText(from: $0)
                )
            }
            await Self.exitFromWait(primitives: primitives, json: output.json)
            return
        }
        if output.json {
            // Non-wait happy path: confirm the post on stdout so a
            // caller can `jq` for the minted identifier on its way to
            // a follow-up `roar dismiss <id>`.
            print(encodeJSON(JSONPostedShape(
                identifier: requestIdentifier,
                posted: true
            )))
        }
        await Self.performExit(ExitPlan(drain: .zero, code: 0))
    }
}
