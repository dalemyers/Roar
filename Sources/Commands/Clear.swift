import ArgumentParser
import Darwin
import Foundation
import UserNotifications

/// Abstraction over the slice of `UNUserNotificationCenter` that
/// `Clear.run` and `pruneUnreferencedDynamicCategories` touch. The
/// concrete `UNUserNotificationCenter` conforms via the `extension`
/// below; tests inject a controllable fake so the full
/// clear-then-prune orchestration can be exercised without driving
/// the real notification daemon (which on a test host responds
/// asynchronously to all six entry points and would make the test
/// flaky and order-sensitive).
protocol ClearCenter {
    /// Wipe every delivered notification. Fire-and-forget on the real
    /// API; the protocol carries the same shape so the test fake can
    /// record the call.
    func removeAllDelivered()
    /// Wipe every pending (scheduled-but-not-fired) request.
    func removeAllPending()
    /// Current registered category set.
    func notificationCategoriesAsync() async -> Set<UNNotificationCategory>
    /// Rewrite the registered category set.
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    /// Currently-delivered notifications. Used to compute which
    /// dynamic categories are still referenced and must survive the
    /// prune.
    func deliveredNotificationsAsync() async -> [UNNotification]
    /// Currently-pending (scheduled) requests.
    func pendingNotificationRequestsAsync() async -> [UNNotificationRequest]
}

extension UNUserNotificationCenter: ClearCenter {
    func removeAllDelivered() { removeAllDeliveredNotifications() }
    func removeAllPending() { removeAllPendingNotificationRequests() }
    func notificationCategoriesAsync() async -> Set<UNNotificationCategory> {
        await notificationCategories()
    }
    func deliveredNotificationsAsync() async -> [UNNotification] {
        await deliveredNotifications()
    }
    func pendingNotificationRequestsAsync() async -> [UNNotificationRequest] {
        await pendingNotificationRequests()
    }
}

/// `roar clear` — remove notifications belonging to this app.
///
/// Scopes (mutually exclusive):
///   * Default (no scope flag): clear only the *delivered* bucket
///     (Notification Center clutter). Pending — scheduled `--in` /
///     `--at` requests yet to fire — is preserved so a `roar clear`
///     does not destroy upcoming work the user explicitly scheduled.
///   * `--delivered`: redundant with the default, kept for explicitness.
///   * `--pending`: clear only the pending bucket.
///   * `--all`: clear both buckets. Equivalent to the historical
///     no-flag behaviour; opt-in now so a typo'd `roar clear` cannot
///     vaporise a user's scheduled notifications.
///
/// `--categories` is a separate, opt-in concern: every `roar send`
/// with custom buttons registers a `roar.dyn.<hash>` category and
/// unions it into the per-bundle category set. Categories never
/// expire on their own, so the set grows monotonically. The flag
/// prunes any `roar.dyn.*` entry that isn't referenced by a
/// currently-delivered or pending notification — safe to run any
/// time, idempotent, and the only way to claw back categories left
/// behind by older sends. Combine with a scope flag to clear and
/// prune in one shot; pass alone to prune without touching
/// notifications.
struct Clear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Remove notifications belonging to this app (delivered only by default; pass --all to also drop scheduled requests)."
    )

    @Flag(
        name: .long,
        help: "Clear only delivered notifications. Same as the default (no scope flag); kept for explicitness. Mutually exclusive with --pending and --all."
    )
    var delivered: Bool = false

    @Flag(
        name: .long,
        help: "Clear only pending (scheduled-but-not-yet-fired) notifications. Mutually exclusive with --delivered and --all."
    )
    var pending: Bool = false

    @Flag(
        name: .long,
        help: "Clear BOTH delivered and pending notifications. Mutually exclusive with --delivered and --pending. Use this when you want the historical 'wipe everything' behaviour — bare `roar clear` is delivered-only so a typo cannot destroy scheduled requests."
    )
    var all: Bool = false

    @Flag(
        name: .long,
        help: "Prune notification categories registered by roar that aren't referenced by any currently delivered or pending notification. Safe to run any time. Combine with a scope flag (--delivered/--pending/--all) to clear notifications and prune in one shot; pass alone to prune without touching notifications."
    )
    var categories: Bool = false

    /// Prefix every `roar`-generated notification category uses. Set
    /// here so the prune in `--categories` mode and the producer in
    /// `Send.categoryIdentifier` cannot drift.
    static let dynamicCategoryPrefix = "roar.dyn."

    @OptionGroup var output: OutputOptions

    /// JSON shape for `roar clear --json`. Reports which buckets the
    /// invocation cleared (so a downstream observer can confirm
    /// `clear --pending` did not touch `delivered`, etc.) and whether
    /// the category prune ran. Boolean fields rather than counts
    /// because UN's `removeAll*` APIs are fire-and-forget — there's
    /// no return value the caller can use to report a precise count.
    struct JSONShape: Encodable, Equatable {
        let deliveredCleared: Bool
        let pendingCleared: Bool
        let categoriesPruned: Bool

        enum CodingKeys: String, CodingKey {
            case deliveredCleared = "delivered_cleared"
            case pendingCleared = "pending_cleared"
            case categoriesPruned = "categories_pruned"
        }
    }

    /// Alias / forwarding accessor for the centralised
    /// `CommandExit` chokepoint. See
    /// `Sources/CommandExit.swift` for the full rationale.
    typealias ExitPlan = CommandExit.Plan

    /// Forwarding accessor for the shared test seam — reads / writes
    /// `CommandExit.hook`. Test files written against the old
    /// per-command name continue to compile.
    static var exitHook: (@Sendable (CommandExit.Plan) async -> Void)? {
        get { CommandExit.hook }
        set { CommandExit.hook = newValue }
    }

    /// Wipe the selected bucket(s) and exit.
    ///
    /// `removeAllDeliveredNotifications` / `removeAllPendingNotificationRequests`
    /// are fire-and-forget (no completion handler) — the XPC reply is
    /// flushed asynchronously, so `exit()` immediately after can race
    /// the flush and leave the clear queued but undelivered. The
    /// small drain at the end matches the rationale of
    /// `RoarAppDelegate.exitDrainDelay`.
    func run() async throws {
        try await runOrchestration(center: UNUserNotificationCenter.current())
        if output.json {
            // Compute the same flags `runOrchestration` used so the
            // JSON output reflects exactly what was performed. The
            // logic mirrors the orchestrator's branching exactly —
            // a regression there would surface here too.
            let onlyCategories = categories && !delivered && !pending && !all
            let didDelivered = !onlyCategories && !pending
            let didPending = !onlyCategories && (pending || all)
            print(encodeJSON(JSONShape(
                deliveredCleared: didDelivered,
                pendingCleared: didPending,
                categoriesPruned: categories
            )))
        }
        // Same XPC drain rationale as the click-response handler;
        // share the constant rather than re-hardcoding the duration.
        // See `RoarAppDelegate.exitDrainDelay` for the full reasoning.
        await CommandExit.perform(
            ExitPlan(drain: RoarAppDelegate.exitDrainDelay, code: 0))
    }

    /// The non-exit half of `run()`. Extracted so tests can drive the
    /// full clear-then-prune decision tree through a fake `ClearCenter`
    /// without the surrounding `Darwin.exit(0)`. The mutual-exclusion
    /// check, the `--categories`-alone preservation guard, and the
    /// per-bucket calls all live here.
    ///
    /// Scope precedence:
    ///   * `--delivered` / `--pending` / `--all` are mutually exclusive.
    ///   * No scope flag — defaults to clearing the delivered bucket
    ///     only (pending is preserved). This is the safer default; a
    ///     forgetful `roar clear` from the shell prompt no longer
    ///     destroys scheduled notifications.
    ///   * `--all` is the explicit opt-in for "wipe both buckets,"
    ///     matching the historical no-flag behaviour.
    ///   * `--categories` alone (no scope flag) prunes the registry
    ///     without clearing any notifications. Without this guard the
    ///     default "delivered-only" rule would still wipe the
    ///     delivered bucket before pruning, which is the opposite of
    ///     "just prune unreferenced categories."
    ///
    /// `internal` (not private) so the XCTest target can call it
    /// directly. Not part of the CLI surface.
    func runOrchestration(center: ClearCenter) async throws {
        try Self.validateScopeFlagsMutualExclusion(
            delivered: delivered, pending: pending, all: all)
        // `--categories` alone (no scope flag) means "just prune."
        // Without this guard the default delivered-only branch below
        // would still fire and clear the bucket, which contradicts
        // the user's intent.
        let onlyCategories = categories && !delivered && !pending && !all
        if !onlyCategories {
            // `--pending` is the only scope that does NOT clear
            // delivered. `--all` and the implicit-default branches
            // clear delivered. `--delivered` likewise clears delivered.
            if !pending {
                center.removeAllDelivered()
            }
            // `--all` and `--pending` clear the pending bucket. The
            // implicit default (no scope flag) does NOT — pending is
            // user-scheduled work and a bare `roar clear` should not
            // destroy it. `--delivered` (explicit) also leaves
            // pending alone.
            if pending || all {
                center.removeAllPending()
            }
        }
        if categories {
            // Prune AFTER the clear (when applicable) so categories
            // referenced only by now-cleared notifications also drop.
            // The remaining-references set is computed against the
            // post-clear state.
            await Self.pruneUnreferencedDynamicCategories(center: center)
        }
    }

    /// Reject scope-flag combinations that are ambiguous. Only one of
    /// `--delivered`, `--pending`, `--all` may be set. Bare `roar
    /// clear` (no scope flag) is the safe default — delivered-only.
    ///
    /// `nonisolated static` so tests can pin the rule without driving
    /// the full orchestration.
    static func validateScopeFlagsMutualExclusion(
        delivered: Bool, pending: Bool, all: Bool
    ) throws {
        var set: [String] = []
        if delivered { set.append("--delivered") }
        if pending { set.append("--pending") }
        if all { set.append("--all") }
        guard set.count >= 2 else { return }
        throw ValidationError(
            "\(set.joined(separator: ", ")) are mutually exclusive. "
            + "Pick one scope, or omit all three to clear delivered only."
        )
    }

    /// Compute the set of `roar.dyn.*` category identifiers still in
    /// use after the (optional) clear above, and rewrite the
    /// notification-center category set to drop everything that
    /// isn't still referenced. Non-`roar.dyn.*` categories (anything
    /// registered by a future hand-rolled `roar` feature, or by a
    /// sibling app sharing the bundle id) are passed through
    /// untouched so this is safe even in a future shared-registry
    /// regime.
    ///
    /// Idempotent: running twice with no intervening change is a
    /// no-op.
    ///
    /// The pure logic of "what should the final category set be?"
    /// lives in `Self.mergePrunedCategories`. The orchestration here
    /// snapshots the world twice — once to compute the prune, then a
    /// second time *immediately before* `setNotificationCategories` —
    /// so that a concurrent `roar send` registering a brand-new
    /// category in the gap is not silently clobbered. There is no
    /// UN-provided compare-and-swap, so true atomicity is impossible;
    /// the double-snapshot just closes most of the race window.
    /// Categories that appear in the second snapshot but not the
    /// first ("additions") are preserved by default, then the same
    /// `roar.dyn.*`-unreferenced rule is applied against the union
    /// of both reference snapshots so we don't paradoxically
    /// resurrect a category the user just made stale.
    ///
    /// `static` so a future `roar categories prune` subcommand could
    /// call the same routine without re-implementing the rules.
    static func pruneUnreferencedDynamicCategories(
        center: ClearCenter
    ) async {
        // Snapshot 1: state at the time we decide what to prune.
        let categories1 = await center.notificationCategoriesAsync()
        let delivered1 = await center.deliveredNotificationsAsync()
        let pending1 = await center.pendingNotificationRequestsAsync()
        let referenced1 = Self.referencedCategoryIDs(
            delivered: delivered1.map { $0.request.content.categoryIdentifier },
            pending: pending1.map { $0.content.categoryIdentifier }
        )

        // Snapshot 2: refreshed view immediately before the write.
        // A concurrent `roar send` that registered a category in
        // between will appear in `categories2` but not `categories1`,
        // and its pending notification will appear in `pending2` —
        // both of which feed into the merge below so the new entry
        // survives.
        let categories2 = await center.notificationCategoriesAsync()
        let delivered2 = await center.deliveredNotificationsAsync()
        let pending2 = await center.pendingNotificationRequestsAsync()
        let referenced2 = Self.referencedCategoryIDs(
            delivered: delivered2.map { $0.request.content.categoryIdentifier },
            pending: pending2.map { $0.content.categoryIdentifier }
        )

        let kept = Self.mergePrunedCategories(
            categories1: categories1,
            categories2: categories2,
            referenced1: referenced1,
            referenced2: referenced2
        )
        // Compare against the latest snapshot — the one whose state
        // we're about to overwrite. Comparing against `categories1`
        // would write whenever any concurrent change happened in the
        // gap, even when our prune produced the same answer the
        // concurrent change already wrote.
        if kept != categories2 {
            center.setNotificationCategories(kept)
        }
    }

    /// Compute the set of category identifiers still referenced by
    /// the surviving notifications. Returns the union of the
    /// delivered and pending lists, filtered to non-empty (an empty
    /// `categoryIdentifier` means the notification didn't register
    /// one and isn't keeping any category alive).
    ///
    /// `nonisolated static` so the rule can be unit-tested without
    /// touching UN.
    static func referencedCategoryIDs(
        delivered: [String], pending: [String]
    ) -> Set<String> {
        var referenced: Set<String> = []
        for id in delivered where !id.isEmpty { referenced.insert(id) }
        for id in pending where !id.isEmpty { referenced.insert(id) }
        return referenced
    }

    /// Filter a notification-center category set: keep everything
    /// that isn't a `roar.dyn.*` entry (preserves any future
    /// hand-rolled or sibling-app categories), and within the
    /// `roar.dyn.*` slice keep only entries referenced by
    /// `referenced`.
    ///
    /// `nonisolated static` so the rule can be unit-tested without
    /// touching UN.
    static func filterPrunedCategories(
        categories: Set<UNNotificationCategory>,
        referenced: Set<String>
    ) -> Set<UNNotificationCategory> {
        var kept = Set<UNNotificationCategory>()
        for category in categories {
            let isDynamic = category.identifier.hasPrefix(dynamicCategoryPrefix)
            if !isDynamic || referenced.contains(category.identifier) {
                kept.insert(category)
            }
        }
        return kept
    }

    /// Compute the final category set under the double-snapshot prune
    /// protocol. The intent is "prune unreferenced `roar.dyn.*` entries
    /// without clobbering a concurrent send's brand-new registration."
    ///
    /// Inputs are two snapshots of the world taken either side of an
    /// arbitrarily-long async gap:
    ///
    ///   * `categories1` / `referenced1`: snapshot at decision time.
    ///   * `categories2` / `referenced2`: snapshot immediately before
    ///     the write.
    ///
    /// The merge:
    ///
    /// 1. Union the two category snapshots into the candidate set —
    ///    every entry we've seen on either side of the gap is a
    ///    candidate. This is the key change from the single-snapshot
    ///    helper: a category present only in `categories2` (added
    ///    during the gap by a concurrent `roar send`) is not lost,
    ///    and a category present only in `categories1` (removed
    ///    during the gap by an external actor) is preserved so we
    ///    don't second-guess external changes.
    /// 2. Apply the standard `filterPrunedCategories` rule to the
    ///    candidate set, but with the references set being the
    ///    UNION of both snapshots' references. A category that was
    ///    referenced in EITHER snapshot is "in use" — using only
    ///    one snapshot's references would either prune a brand-new
    ///    pending notification's category (using R1) or prune a
    ///    just-cleared notification's category prematurely (using
    ///    R2 alone). The union is the safe interpretation of "in
    ///    use during the prune window."
    ///
    /// The trade-off of unioning categories: an external actor that
    /// genuinely wanted to drop a `roar.dyn.*` entry between
    /// snapshots would have their drop reverted. That's an acceptable
    /// price — the only writer to the category set is
    /// `setNotificationCategories`, and the only call sites in
    /// `roar` are `Send.registerDynamicCategory` (adds) and this
    /// function (prunes). A drop by an external actor here is
    /// either another `roar` instance (in which case re-running
    /// the prune is idempotent and will drop again) or a
    /// sibling app sharing the bundle id (in which case our
    /// concurrent-send-preservation rule applies symmetrically:
    /// don't clobber their work).
    ///
    /// `nonisolated static` so the rule can be unit-tested without
    /// touching UN. The orchestration in `pruneUnreferencedDynamicCategories`
    /// is thin glue over this function.
    static func mergePrunedCategories(
        categories1: Set<UNNotificationCategory>,
        categories2: Set<UNNotificationCategory>,
        referenced1: Set<String>,
        referenced2: Set<String>
    ) -> Set<UNNotificationCategory> {
        // Union both snapshots' category sets — every entry we've
        // ever observed during the prune window is a candidate. A
        // category that was removed by an external actor between
        // snapshots survives as a `kept1`-side entry; a category
        // that was added by a concurrent `roar send` survives as
        // a `kept2`-side entry. The dynamic-prune filter below
        // strips genuinely stale entries from this union.
        let candidates = categories1.union(categories2)
        // Reference union — a category referenced by EITHER
        // snapshot is in use. See doc comment for the rationale
        // (using only one snapshot would either lose a concurrent
        // send's pending category, or prune a still-delivered
        // notification's category prematurely).
        let referencedAny = referenced1.union(referenced2)
        return filterPrunedCategories(
            categories: candidates, referenced: referencedAny)
    }
}
