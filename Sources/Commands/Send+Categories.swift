import CryptoKit
import Foundation
import UserNotifications

extension Send {
    /// Build a category id that is stable for a given (sorted) set of
    /// actions, *across processes*. Concurrent or sequential
    /// `roar send` invocations with the same button set then share a
    /// category, which keeps the persisted `setNotificationCategories`
    /// registry from growing unboundedly across reboots.
    ///
    /// Swift's `Hasher` is randomized per process by design — using
    /// it here would produce a different `roar.dyn.<value>` on every
    /// invocation and turn the registry into an append-only set with
    /// thousands of duplicates over the system's lifetime.
    /// `SHA256` gives a deterministic, well-distributed digest; we
    /// take only the first 8 bytes (64 bits) because category-id
    /// collisions are bounded by the number of distinct button shapes
    /// the CLI ever produces, and 64 bits is many orders of magnitude
    /// of headroom.
    ///
    /// `nonisolated static` so tests can pin the stable-id contract
    /// without spinning up a notification center.
    static func categoryIdentifier(
        for actions: [ParsedAction],
        hiddenPreviewsBodyPlaceholder: String? = nil,
        categorySummaryFormat: String? = nil,
        extraCategoryOptions: UNNotificationCategoryOptions = []
    ) -> String {
        // Canonical form encodes everything that distinguishes one
        // action shape from another so the digest changes whenever
        // the rendered category would change. Fields are joined with
        // U+001F (unit separator); actions with U+001E (record
        // separator). Field order: id, title, options.rawValue,
        // kindTag, placeholder, buttonTitle. The kind+placeholder+
        // buttonTitle fields are always present so the schema is
        // stable — button-kind actions emit "B" / "" / "" rather than
        // a shorter form that would collide with a future variant.
        let actionsBlock = actions
            .sorted { $0.id < $1.id }
            .map { action -> String in
                let kindTag: String
                let placeholder: String
                let buttonTitle: String
                switch action.kind {
                case .button:
                    kindTag = "B"
                    placeholder = ""
                    buttonTitle = ""
                case .textInput(let p, let bt):
                    kindTag = "T"
                    placeholder = p
                    buttonTitle = bt
                }
                return [
                    action.id,
                    action.title,
                    "\(action.options.rawValue)",
                    kindTag,
                    placeholder,
                    buttonTitle,
                ].joined(separator: "\u{1F}")
            }
            .joined(separator: "\u{1E}")
        // Category-level metadata participates in the hash so two
        // sends with the same action shape but different preview /
        // summary text get distinct category registrations. Without
        // this, the union-insert in `setNotificationCategories`
        // would silently drop the new metadata in favour of the
        // previously-registered identical id. U+001D (group
        // separator) demarcates the action block from the metadata
        // block so the two cannot collide through clever input.
        //
        // When BOTH metadata fields are nil, the canonical form
        // omits the group-separator + empty-metadata suffix
        // entirely. This keeps the hash byte-compatible with
        // categories registered by older roar binaries — a build
        // that predates the metadata fields registered an id from
        // just the actions block, and we want the same set of
        // actions to keep producing the same identifier so reposts
        // continue replacing prior deliveries instead of leaking a
        // duplicate registry entry.
        // Build the canonical form in three layers so each new metadata
        // axis stays bit-compatible with categories registered by older
        // roar binaries that didn't know about it:
        //
        //   * Layer 1 (always): the sorted actions block.
        //   * Layer 2 (only when placeholder OR summary is set): the
        //     hidden-previews-text block. Two-field schema kept
        //     unchanged from the previous build so a send that only sets
        //     `--hide-previews-body-placeholder` hashes the same id
        //     across upgrades.
        //   * Layer 3 (only when extraCategoryOptions is non-empty):
        //     the category-flags block. Hangs off its own group
        //     separator so the layer-2 schema stays untouched. Two
        //     sends with the same actions + placeholder but different
        //     `--show-title-when-previews-hidden` settings get distinct
        //     ids — without this, `setNotificationCategories`
        //     union-insert would keep whichever flag setting got
        //     registered first.
        var canonical = actionsBlock
        if hiddenPreviewsBodyPlaceholder != nil || categorySummaryFormat != nil {
            let metadataBlock = [
                hiddenPreviewsBodyPlaceholder ?? "",
                categorySummaryFormat ?? "",
            ].joined(separator: "\u{1F}")
            canonical += "\u{1D}" + metadataBlock
        }
        if !extraCategoryOptions.isEmpty {
            canonical += "\u{1D}" + "\(extraCategoryOptions.rawValue)"
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        // First 8 bytes (16 hex chars) — see the doc comment for the
        // collision-headroom argument. The `roar.dyn` prefix is what
        // a future cleanup script (`getNotificationCategories`,
        // filter on prefix) would key off of to distinguish our
        // generated categories from any future hand-rolled ones.
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "roar.dyn.\(hex)"
    }

    /// Stable identifier for the no-actions, dismiss-observable
    /// category used when `--wait` is set but no `--action` /
    /// `--text-action` was supplied. Without a category, UN cannot
    /// attach the `.customDismissAction` option, so a swipe-dismiss
    /// in plain `--wait` mode never fires `didReceive` and the wait
    /// hangs until the timeout. Always registering one stable empty
    /// category keeps `setNotificationCategories` from growing
    /// unboundedly: every `--wait` invocation without buttons reuses
    /// the same identifier.
    static let dismissableEmptyCategoryID = "roar.dyn.dismissable"

    /// Build the `UNNotificationCategory` for this invocation. Returns
    /// `nil` when no actions were supplied AND `dismissableEvenIfEmpty`
    /// is `false` (no category needed, content omits `categoryIdentifier`).
    ///
    /// Sets the category's `.customDismissAction` option so the
    /// framework fires `didReceive` with `UNNotificationDismissActionIdentifier`
    /// when the user swipes the banner away. Without it, dismissal
    /// is silent and `--wait` hangs until the timeout instead of
    /// printing `dismiss\n` and exiting promptly.
    ///
    /// `dismissableEvenIfEmpty` is set by the caller to `true` in
    /// `--wait` mode so the empty-actions path still gets a
    /// `.customDismissAction`-bearing category; otherwise `--wait`
    /// without `--action`/`--text-action` would lose dismiss
    /// observability entirely (the very gap `.customDismissAction`
    /// exists to close).
    ///
    /// `nonisolated static` so tests can drive the construction
    /// without setting up the full Send invocation.
    static func buildCategory(
        for actions: [ParsedAction],
        dismissableEvenIfEmpty: Bool = false,
        hiddenPreviewsBodyPlaceholder: String? = nil,
        categorySummaryFormat: String? = nil,
        extraCategoryOptions: UNNotificationCategoryOptions = []
    ) -> UNNotificationCategory? {
        // When the action list is empty, the only reason to register a
        // category at all is to attach `.customDismissAction` (for
        // `--wait` mode), one of the preview/summary strings, or an
        // explicit category-options flag (`--show-title-when-previews-hidden`
        // etc.). If none of those apply, return nil and let the content
        // go out without a category id.
        let metadataPresent =
            hiddenPreviewsBodyPlaceholder != nil
            || categorySummaryFormat != nil
            || !extraCategoryOptions.isEmpty
        if actions.isEmpty, !dismissableEvenIfEmpty, !metadataPresent {
            return nil
        }
        let unActions: [UNNotificationAction] = actions.map { parsed in
            switch parsed.kind {
            case .button:
                return UNNotificationAction(
                    identifier: parsed.id,
                    title: parsed.title,
                    options: parsed.options
                )
            case .textInput(let placeholder, let buttonTitle):
                return UNTextInputNotificationAction(
                    identifier: parsed.id,
                    title: parsed.title,
                    options: parsed.options,
                    textInputButtonTitle: buttonTitle,
                    textInputPlaceholder: placeholder
                )
            }
        }
        // The dismissable-empty fallback id is only used when there
        // are no actions AND no preview/summary metadata — that's the
        // case where every `--wait` invocation reuses the same
        // category. Adding preview/summary text turns it into a
        // hashed id so the registry doesn't grow unboundedly while
        // still letting each unique (text) combination get its own
        // entry.
        let identifier: String
        if actions.isEmpty, !metadataPresent {
            identifier = dismissableEmptyCategoryID
        } else {
            identifier = categoryIdentifier(
                for: actions,
                hiddenPreviewsBodyPlaceholder: hiddenPreviewsBodyPlaceholder,
                categorySummaryFormat: categorySummaryFormat,
                extraCategoryOptions: extraCategoryOptions
            )
        }
        // UN's `init(identifier:actions:intentIdentifiers:hiddenPreviewsBodyPlaceholder:options:)`
        // takes the placeholder string in the initializer (no setter
        // exposed). The summaryFormat overload adds the format string;
        // we always pass `categorySummaryFormat ?? ""` because UN
        // treats empty as "no override," matching the framework
        // default. The hidden placeholder, by contrast, is omitted
        // from the init when nil so UN's own default placeholder
        // ("Notification") still applies.
        //
        // `.customDismissAction` is always set so swipe-dismissal in
        // `--wait` mode routes through `didReceive`. Extra options
        // (`hiddenPreviewsShowTitle` / `hiddenPreviewsShowSubtitle`
        // from the new flags) are unioned in; the framework treats
        // unknown bits as 0, so older OS versions silently ignore
        // anything they don't recognise.
        var options: UNNotificationCategoryOptions = [.customDismissAction]
        options.formUnion(extraCategoryOptions)
        if let placeholder = hiddenPreviewsBodyPlaceholder {
            return UNNotificationCategory(
                identifier: identifier,
                actions: unActions,
                intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: placeholder,
                categorySummaryFormat: categorySummaryFormat ?? "",
                options: options
            )
        }
        if let summary = categorySummaryFormat {
            return UNNotificationCategory(
                identifier: identifier,
                actions: unActions,
                intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: nil,
                categorySummaryFormat: summary,
                options: options
            )
        }
        return UNNotificationCategory(
            identifier: identifier,
            actions: unActions,
            intentIdentifiers: [],
            options: options
        )
    }

    /// Translate the `--show-title-when-previews-hidden` and
    /// `--show-subtitle-when-previews-hidden` flags into the
    /// `UNNotificationCategoryOptions` bits that
    /// `buildCategory(extraCategoryOptions:)` unions in. The flags are
    /// independent and may be combined freely.
    ///
    /// `nonisolated static` so tests can pin the mapping without driving
    /// ArgumentParser.
    ///
    /// - Parameters:
    ///   - showTitle: The `--show-title-when-previews-hidden` flag value.
    ///   - showSubtitle: The `--show-subtitle-when-previews-hidden` flag value.
    /// - Returns: The option set to union into the category's options.
    ///   Empty when neither flag was set.
    static func buildHiddenPreviewsCategoryOptions(
        showTitle: Bool,
        showSubtitle: Bool
    ) -> UNNotificationCategoryOptions {
        var options: UNNotificationCategoryOptions = []
        if showTitle { options.insert(.hiddenPreviewsShowTitle) }
        if showSubtitle { options.insert(.hiddenPreviewsShowSubtitle) }
        return options
    }

    /// Assemble the `userInfo` dictionary that `add(_:)` will copy
    /// onto the notification request. The contents are derived
    /// *only* from pre-validated flag values — `--exec`,
    /// `--open-url`, `--activate-bundle-id`,
    /// `--foreground-presentation`, and the exact URL-scheme
    /// allow-list the send-time validator agreed to — none of which
    /// depend on the piped body or the resolved attachments.
    /// Factored out of `run()` so the construction (and its
    /// companion size check) can be invoked from tests, and so the
    /// ordering guarantee in `run()` (userInfo built and
    /// size-checked *before* draining stdin) is visibly hoisted to
    /// the top of the function rather than buried in `content`-
    /// setup territory.
    ///
    /// `nonisolated static` so the call site doesn't need an instance.
    ///
    /// - Parameters:
    ///   - activateBundleID: Validated `--activate-bundle-id` value.
    ///   - exec: Validated `--exec` value.
    ///   - resolvedOpenURL: Validated `--open-url` value (post
    ///     `validateOpenURLIfPresent`).
    ///   - openUrlAllowList: The exact set of URL schemes the send-
    ///     time validator agreed to. Serialised into userInfo and
    ///     replayed at click time so the click handler validates
    ///     against the SAME allow-list — not a hardcoded default,
    ///     not "any scheme". `nil` when `resolvedOpenURL` is `nil`
    ///     (no click-time URL → no allow-list to ship).
    ///   - resolvedForegroundPresentation: Parsed
    ///     `--foreground-presentation` value, or `nil`.
    /// - Returns: The dictionary to store on `content.userInfo`.
    static func buildUserInfo(
        activateBundleID: String?,
        exec: String?,
        resolvedOpenURL: String?,
        openUrlAllowList: Set<String>?,
        resolvedForegroundPresentation: ForegroundPresentation?
    ) -> [String: String] {
        var userInfo: [String: String] = [:]
        if let activateBundleID { userInfo["roar.activate.bundleID"] = activateBundleID }
        if let exec {
            userInfo["roar.exec.command"] = exec
            userInfo["roar.exec.consent"] = "1"
        }
        if let resolvedOpenURL {
            userInfo["roar.open.url"] = resolvedOpenURL
            // Serialise the exact allow-list used at send time. The
            // click handler reads this back via
            // `URLValidation.deserializeAllowList` and uses it as
            // the allow-list for the click-time re-parse — so the
            // click can never widen what the send agreed to. (A
            // same-bundle-id spoofer can still rewrite this entry;
            // that's the inherent limit of the ad-hoc-signing
            // threat model, documented in the README.) The default
            // allow-list flows in too: a send without
            // `--allow-url-scheme` still emits `http,https,mailto`
            // here so the click re-parser doesn't fall back to an
            // implicit default that could drift from the send-time
            // contract.
            let allowList = openUrlAllowList ?? URLValidation.defaultOpenSchemes
            userInfo["roar.open.allowedSchemes"] =
                URLValidation.serializeAllowList(allowList)
        }
        // Foreground-presentation hint reaches the delegate via userInfo
        // rather than a side channel because the willPresent callback
        // can fire on a different process invocation than the one that
        // posted the notification (a scheduled trigger reaches usernoted
        // long after `roar send` has exited; a future click-handler
        // relaunch sees the same delegate). The notification request
        // carries everything that should influence its own display.
        // Stored only when the user explicitly opted in — absence
        // preserves the historical banner+list+sound+badge default.
        if let resolvedForegroundPresentation {
            userInfo["roar.present.options"] = resolvedForegroundPresentation.serialized
        }
        return userInfo
    }
}
