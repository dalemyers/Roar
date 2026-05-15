import ArgumentParser
import Darwin
import Foundation
import UserNotifications

/// `roar dismiss <id> [<id>...]` — remove one or more notifications by
/// identifier.
///
/// Targets both the *delivered* (already-fired, still in Notification
/// Center) and *pending* (scheduled via `--in`/`--at` but not yet
/// fired) sets in a single call. The user typed an identifier — what
/// they almost certainly want is "make that one go away regardless of
/// which bucket it's in," and UN exposes separate APIs for the two so
/// we just call both.
///
/// Unknown identifiers (typos, already-dismissed notifications) are
/// reported to stderr by name. If at least one identifier matched
/// something the exit code is 0; if NONE matched, the exit code is
/// `noMatchExitCode` so scripts can distinguish "you deleted what you
/// asked for" from "your id was wrong." UN's underlying remove APIs
/// silently no-op on unknown ids — the diagnostic happens here at the
/// CLI layer, not inside UN.
struct Dismiss: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dismiss",
        abstract: "Remove notifications by identifier."
    )

    @Argument(
        help: "One or more notification identifiers (as passed to `--identifier` at send time, or shown in the first column of `roar list`)."
    )
    var identifiers: [String]

    /// Exit code used when none of the supplied identifiers matched a
    /// delivered or pending notification. Distinct from 0 (at least
    /// one matched) and from ArgumentParser's 64 (EX_USAGE) so shell
    /// scripts can branch on the three outcomes. UN's underlying
    /// remove APIs do not surface a "not found" signal — without this
    /// the user could repeatedly mistype an identifier and get the
    /// same silent success every time.
    static let noMatchExitCode: Int32 = 4

    @OptionGroup var output: OutputOptions

    /// JSON shape for `roar dismiss --json`. `requested` is the
    /// user's argv (preserved order, including duplicates). `unknown`
    /// is the deduplicated subset that didn't match any delivered
    /// or pending notification — same data the text path emits to
    /// stderr, only here it's structured for downstream consumers.
    struct JSONShape: Encodable, Equatable {
        let requested: [String]
        let unknown: [String]
    }

    /// Alias / forwarding accessor for the centralised
    /// `CommandExit` chokepoint. See `Sources/CommandExit.swift`.
    typealias ExitPlan = CommandExit.Plan

    static var exitHook: (@Sendable (CommandExit.Plan) async -> Void)? {
        get { CommandExit.hook }
        set { CommandExit.hook = newValue }
    }

    /// Remove the named notifications and exit.
    ///
    /// `removeDeliveredNotifications(withIdentifiers:)` and
    /// `removePendingNotificationRequests(withIdentifiers:)` are both
    /// fire-and-forget — there is no completion handler to await, no
    /// failure surface to handle. The call is essentially "post this
    /// message to usernoted and return," and because the XPC reply is
    /// flushed asynchronously, `exit()` immediately after the call
    /// can race the flush and leave the removal queued but
    /// undelivered. The small drain at the end matches the rationale
    /// of `RoarAppDelegate.exitDrainDelay`.
    ///
    /// Before the remove calls we snapshot the delivered + pending
    /// identifier sets and compute which of the user's ids are
    /// "unknown" (no match in either bucket). Unknowns are reported
    /// to stderr. If every id is unknown the exit code becomes
    /// `noMatchExitCode` so scripts notice — without this signal a
    /// typo'd `roar dismiss` returns 0 and the user assumes the
    /// notification was removed.
    func run() async throws {
        try Self.validateIdentifiers(identifiers)
        let unknownIDs = try await runOrchestration(
            center: UNUserNotificationCenter.current())
        if output.json {
            print(encodeJSON(JSONShape(
                requested: identifiers,
                unknown: unknownIDs
            )))
        } else {
            Self.reportUnknownIdentifiers(unknownIDs)
        }
        let exitCode = Self.exitCode(
            unknownIDs: unknownIDs, requested: identifiers)
        // Same XPC drain rationale as the click-response handler;
        // share the constant rather than re-hardcoding the duration.
        // See `RoarAppDelegate.exitDrainDelay` for the full reasoning.
        // The drain runs even on the no-match exit path because the
        // remove APIs were still invoked (UN silently no-op'd them)
        // and the XPC reply still needs to flush.
        await CommandExit.perform(
            ExitPlan(drain: RoarAppDelegate.exitDrainDelay, code: exitCode))
    }

    /// Abstraction over the slice of `UNUserNotificationCenter` that
    /// `Dismiss.run` touches. The concrete `UNUserNotificationCenter`
    /// conforms via the extension below; tests inject a controllable
    /// fake so the full dismiss orchestration (including which
    /// identifier-bearing methods get called and which ids are
    /// reported as unknown) is observable.
    ///
    /// The identifier-snapshot methods return `[String]` (not
    /// `[UNNotification]` / `[UNNotificationRequest]`) so test fakes
    /// can seed delivered/pending ids directly. `UNNotification` has
    /// no public initialiser, so a protocol that returned the
    /// framework type would leave the delivered-id matching path
    /// untestable. The concrete extension on
    /// `UNUserNotificationCenter` does the `.identifier` mapping
    /// once, so production code touches the real UN APIs and tests
    /// touch a strings-only fake.
    protocol DismissCenter {
        func removeDeliveredNotifications(withIdentifiers: [String])
        func removePendingNotificationRequests(withIdentifiers: [String])
        /// Identifiers of currently-delivered notifications. Feeds
        /// the "did anything match?" calculation that drives the
        /// exit code and stderr warning.
        func deliveredIdentifiersAsync() async -> [String]
        /// Identifiers of currently-pending (scheduled-but-not-yet-
        /// fired) requests. Same role as `deliveredIdentifiersAsync`.
        func pendingIdentifiersAsync() async -> [String]
    }

    /// The non-exit half of `run()`. Extracted so tests can drive the
    /// remove-delivered / remove-pending sequence through a fake
    /// `DismissCenter` without the surrounding `Darwin.exit(0)`.
    ///
    /// Snapshots the existing identifier set BEFORE the removes so
    /// the "did anything match?" check sees the pre-clear state. The
    /// removes themselves are invoked unconditionally — both UN APIs
    /// are silent no-ops on unknown ids, so passing the full user
    /// list is safe and one less branch to keep in sync with the
    /// matching logic.
    ///
    /// `internal` (not private) so the XCTest target can call it
    /// directly. Not part of the CLI surface.
    ///
    /// - Returns: The subset of `identifiers` that did NOT match any
    ///   delivered or pending notification at snapshot time. Order
    ///   preserved so the caller's stderr report names ids in the
    ///   order the user typed them. Empty if every id matched.
    @discardableResult
    func runOrchestration(center: DismissCenter) async throws -> [String] {
        let deliveredIDs = await center.deliveredIdentifiersAsync()
        let pendingIDs = await center.pendingIdentifiersAsync()
        let known: Set<String> = Set(deliveredIDs).union(pendingIDs)
        // Preserve the user's argv order and de-duplicate while
        // building the unknown list: a user who passes the same
        // typo twice should see it once in the warning, not twice.
        var seen = Set<String>()
        var unknowns: [String] = []
        for id in identifiers where !known.contains(id) && seen.insert(id).inserted {
            unknowns.append(id)
        }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        return unknowns
    }

    /// Decide the `Dismiss.run` exit code from the orchestration's
    /// unknown-id list and the user's argv.
    ///
    /// The contract: return `noMatchExitCode` when NONE of the distinct
    /// ids the user typed matched a delivered or pending notification,
    /// `0` otherwise. The naïve "did unknowns.count equal
    /// requested.count?" form is wrong in the presence of duplicate
    /// argv ids: `runOrchestration` de-duplicates `unknownIDs` (so the
    /// same typo is reported once), but `requested.count` keeps every
    /// argv entry. `roar dismiss foo foo` against an unknown "foo"
    /// then computed `unknowns.count(1) == requested.count(2) == false`
    /// and exited 0 — even though nothing was dismissed. Comparing
    /// de-duplicated sets answers the actual question ("did every
    /// distinct id fail?") and pins the exit code regardless of
    /// argv repetition.
    ///
    /// `nonisolated static` so tests can drive the decision directly
    /// without round-tripping through `runOrchestration` + the exit
    /// hook.
    static func exitCode(unknownIDs: [String], requested: [String]) -> Int32 {
        Set(unknownIDs) == Set(requested) ? noMatchExitCode : 0
    }

    /// Emit a stderr warning naming the identifiers that didn't match
    /// any delivered or pending notification. Single line per id so
    /// the output composes with `grep`. No-op when `unknownIDs` is
    /// empty (the all-matched happy path is silent — there's nothing
    /// to surface).
    ///
    /// `nonisolated static` so tests can drive the formatting without
    /// constructing a real `Dismiss`.
    static func reportUnknownIdentifiers(_ unknownIDs: [String]) {
        guard !unknownIDs.isEmpty else { return }
        // The ids are already screened for control characters by
        // `validateIdentifiers`, so embedding them in stderr is safe
        // (no terminal-escape-sequence injection). Quote each id so
        // a trailing-whitespace typo is visible to the user.
        let lines = unknownIDs.map { "warning: no notification with identifier '\($0)' (not delivered, not pending).\n" }
        let payload = lines.joined()
        FileHandle.standardError.write(Data(payload.utf8))
    }

    /// Reject empty / whitespace-only identifier arguments. UN
    /// silently no-ops on empty identifiers; surface the misuse
    /// up-front so the user notices their `dismiss ""` didn't do
    /// anything.
    ///
    /// Extracted `static` so tests can pin the rule without driving
    /// ArgumentParser.
    static func validateIdentifiers(_ identifiers: [String]) throws {
        guard !identifiers.isEmpty else {
            throw ValidationError(
                "Provide at least one notification identifier to dismiss."
            )
        }
        // The identifier was produced by `--identifier` at send time
        // and rejected NUL / control characters there. Mirror that
        // discipline here so a hand-typed `dismiss "build\0other"`
        // doesn't truncate at the XPC bridge and silently no-op
        // (or, worse, remove a different request whose identifier
        // matches the truncated prefix).
        for id in identifiers {
            // Bind to `_`: the trimmed return value is intentionally
            // discarded here. Dismiss iterates identifiers that were
            // already minted by a prior `--identifier` at send time
            // (which trimmed them); the inner loop is a defensive
            // re-check against hand-typed `dismiss "build\0other"`,
            // not a canonicalisation step. The downstream `remove*`
            // APIs receive the original `identifiers` array.
            _ = try SharedValidation.requireNonBlank(
                id,
                flag: "Notification identifiers",
                rejectControlCharacters: true,
                controlCharactersAdvice:
                    "NUL truncates downstream string consumers."
            )
        }
    }
}

extension UNUserNotificationCenter: Dismiss.DismissCenter {
    func deliveredIdentifiersAsync() async -> [String] {
        await deliveredNotifications().map(\.request.identifier)
    }
    func pendingIdentifiersAsync() async -> [String] {
        await pendingNotificationRequests().map(\.identifier)
    }
}
