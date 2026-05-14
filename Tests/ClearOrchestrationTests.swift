import XCTest
import ArgumentParser
import os
import UserNotifications
@testable import roar

/// End-to-end tests for `Clear.runOrchestration` — the full
/// clear-then-prune decision tree exercised through a fake
/// `ClearCenter`. The pure helpers `referencedCategoryIDs` /
/// `filterPrunedCategories` are covered separately by
/// `CategoryPruneTests`; this file pins the order and combinations
/// in which the orchestrator invokes the center's methods.
///
/// A regression in any of these tests means a user's `roar clear`
/// invocation does something other than what the help text claims —
/// e.g. `--categories` alone silently wipes notifications, or
/// `--delivered` + `--pending` slips past the mutual-exclusion
/// guard and obliterates everything.
final class ClearOrchestrationTests: XCTestCase {

    /// Defensive teardown: every test that installs `Clear.exitHook`
    /// also registers a local `defer { ... = nil }`, but a throw
    /// before the `defer` line would leak the hook into the next
    /// test in the suite. Clearing unconditionally here is cheap and
    /// makes the suite robust to that whole class of regression.
    override func tearDown() {
        Clear.exitHook = nil
        super.tearDown()
    }

    /// Records every call made against a `ClearCenter` so tests can
    /// assert "X was called, Y was not, both in this order." Async
    /// fetches are seeded from per-snapshot deques so a test can
    /// simulate state changes between the first and second
    /// snapshots taken by `pruneUnreferencedDynamicCategories`.
    final class FakeClearCenter: ClearCenter {
        enum Call: Equatable {
            case removeAllDelivered
            case removeAllPending
            case fetchCategories
            case fetchDelivered
            case fetchPending
            case setCategories(Set<UNNotificationCategory>)
        }

        private(set) var calls: [Call] = []
        // Deques so the orchestrator can fetch twice (Snapshot 1 +
        // Snapshot 2) and a test can model "a concurrent send
        // registered a new category between the snapshots" by
        // queueing a different value for the second pop. A test
        // that only registers one value re-uses it for every fetch.
        private var categoriesQueue: [Set<UNNotificationCategory>] = []
        private var deliveredQueue: [[UNNotification]] = []
        private var pendingQueue: [[UNNotificationRequest]] = []
        private(set) var lastWrittenCategories: Set<UNNotificationCategory>?

        func seed(
            categories: Set<UNNotificationCategory> = [],
            delivered: [UNNotification] = [],
            pending: [UNNotificationRequest] = []
        ) {
            categoriesQueue.append(categories)
            deliveredQueue.append(delivered)
            pendingQueue.append(pending)
        }

        func removeAllDelivered() { calls.append(.removeAllDelivered) }
        func removeAllPending() { calls.append(.removeAllPending) }

        func notificationCategoriesAsync() async -> Set<UNNotificationCategory> {
            calls.append(.fetchCategories)
            // Repeat the last seed if the queue is exhausted —
            // most tests only care about one snapshot.
            let value = categoriesQueue.count > 1
                ? categoriesQueue.removeFirst()
                : categoriesQueue.first ?? []
            return value
        }
        func deliveredNotificationsAsync() async -> [UNNotification] {
            calls.append(.fetchDelivered)
            let value = deliveredQueue.count > 1
                ? deliveredQueue.removeFirst()
                : deliveredQueue.first ?? []
            return value
        }
        func pendingNotificationRequestsAsync() async -> [UNNotificationRequest] {
            calls.append(.fetchPending)
            let value = pendingQueue.count > 1
                ? pendingQueue.removeFirst()
                : pendingQueue.first ?? []
            return value
        }
        func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
            calls.append(.setCategories(categories))
            lastWrittenCategories = categories
        }
    }

    /// Parse a `Clear` command from arg-vector form. ArgumentParser
    /// uses property wrappers (`@Flag`) that are not initialized by
    /// the bare `Clear()` constructor — direct construction crashes
    /// at "Can't read a value from a parsable argument definition"
    /// the first time a flag is accessed. Going through the
    /// public `parse` API initializes every property correctly.
    private func parseClear(_ args: [String]) throws -> Clear {
        try Clear.parse(args)
    }

    // MARK: - Mode combinations

    /// `--delivered` alone — only the delivered bucket should be
    /// touched. Pending is preserved (mutual-exclusion partner) and
    /// the prune is skipped entirely (no `--categories` flag).
    func testDeliveredOnlyMode() async throws {
        let cmd = try parseClear(["--delivered"])
        let fake = FakeClearCenter()
        try await cmd.runOrchestration(center: fake)
        XCTAssertEqual(fake.calls, [.removeAllDelivered])
    }

    /// `--pending` alone — symmetric to the above.
    func testPendingOnlyMode() async throws {
        let cmd = try parseClear(["--pending"])
        let fake = FakeClearCenter()
        try await cmd.runOrchestration(center: fake)
        XCTAssertEqual(fake.calls, [.removeAllPending])
    }

    /// `--categories` alone is the critical case: the prune must run
    /// but NEITHER bucket may be cleared. Without this guard a user
    /// pruning stale categories would lose every notification on
    /// screen.
    func testCategoriesAloneDoesNotClearNotifications() async throws {
        let cmd = try parseClear(["--categories"])
        let fake = FakeClearCenter()
        fake.seed() // empty world
        try await cmd.runOrchestration(center: fake)
        XCTAssertFalse(fake.calls.contains(.removeAllDelivered),
                       "--categories alone must not clear delivered")
        XCTAssertFalse(fake.calls.contains(.removeAllPending),
                       "--categories alone must not clear pending")
        // The prune still ran (it's the whole point of the flag).
        XCTAssertTrue(fake.calls.contains(.fetchCategories))
    }

    /// Default mode (no flags) — only the delivered bucket is
    /// wiped; pending is preserved. `--all` is the new opt-in for
    /// the historical wipe-everything behaviour. Pinning this here
    /// catches a regression where bare `roar clear` silently goes
    /// back to nuking scheduled notifications.
    func testDefaultModeClearsDeliveredOnly() async throws {
        let cmd = try parseClear([])
        let fake = FakeClearCenter()
        try await cmd.runOrchestration(center: fake)
        XCTAssertTrue(fake.calls.contains(.removeAllDelivered))
        XCTAssertFalse(
            fake.calls.contains(.removeAllPending),
            "Bare `roar clear` must NOT touch pending — use --all for that."
        )
        // No `--categories`, so the prune is skipped — no fetch* or
        // setCategories calls should appear.
        XCTAssertFalse(fake.calls.contains(.fetchCategories))
    }

    /// `--all` is the explicit opt-in for clearing BOTH buckets.
    /// Equivalent to the previous no-flag behaviour.
    func testAllModeClearsBothBuckets() async throws {
        let cmd = try parseClear(["--all"])
        let fake = FakeClearCenter()
        try await cmd.runOrchestration(center: fake)
        XCTAssertTrue(fake.calls.contains(.removeAllDelivered))
        XCTAssertTrue(fake.calls.contains(.removeAllPending))
        XCTAssertFalse(fake.calls.contains(.fetchCategories))
    }

    /// `--categories` + `--delivered`: clear delivered, then prune.
    /// Pending must be preserved (the `--delivered` scope excludes
    /// it). The prune ordering is "after the clear" so categories
    /// referenced only by the just-cleared notifications drop too.
    func testCategoriesPlusDeliveredCombo() async throws {
        let cmd = try parseClear(["--categories", "--delivered"])
        let fake = FakeClearCenter()
        fake.seed()
        try await cmd.runOrchestration(center: fake)
        XCTAssertTrue(fake.calls.contains(.removeAllDelivered))
        XCTAssertFalse(fake.calls.contains(.removeAllPending),
                       "--delivered scope must not touch pending")
        // Prune ran AFTER the clear.
        let deliveredIdx = fake.calls.firstIndex(of: .removeAllDelivered)!
        let fetchIdx = fake.calls.firstIndex(of: .fetchCategories)!
        XCTAssertLessThan(deliveredIdx, fetchIdx,
                          "Prune must run AFTER the clear so references reflect post-clear state")
    }

    /// The mutual-exclusion guard. `--delivered`, `--pending`, and
    /// `--all` each name a distinct scope; passing more than one is
    /// ambiguous (which scope wins?). Surfacing the conflict is the
    /// only way to keep the help text honest.
    func testScopeFlagsMutuallyExclusive() async throws {
        // Every pair must fail. Iterating keeps a future combination
        // (e.g. a new `--archived` scope) from sneaking through
        // without a paired rejection test.
        let conflicts: [[String]] = [
            ["--delivered", "--pending"],
            ["--delivered", "--all"],
            ["--pending", "--all"],
        ]
        for args in conflicts {
            let cmd = try parseClear(args)
            let fake = FakeClearCenter()
            do {
                try await cmd.runOrchestration(center: fake)
                XCTFail("Expected ValidationError for \(args), got success")
            } catch let error as ValidationError {
                let msg = String(describing: error)
                XCTAssertTrue(
                    msg.contains("mutually exclusive"),
                    "Expected 'mutually exclusive' for \(args), got: \(msg)"
                )
            } catch {
                XCTFail(
                    "Expected ValidationError for \(args), got \(type(of: error))"
                )
            }
            XCTAssertTrue(
                fake.calls.isEmpty,
                "Mutual-exclusion check must fire before any center calls "
                + "for \(args)"
            )
        }
    }

    // MARK: - Exit hook (call-site pinning)

    /// `Clear.run` default mode: both buckets cleared, prune skipped
    /// (no `--categories`), drain is `exitDrainDelay`, exit code 0.
    /// Removing the post-orchestration sleep at the call site (e.g.
    /// dropping `try? await Task.sleep(...)` in a refactor) would
    /// fail this test even though the helper-level tests would
    /// still pass — that's the integration regression C2 closes.
    func testRunDefaultDrainAndExit() async throws {
        // `OSAllocatedUnfairLock` because the hook fires from an
        // async context and `NSLock.lock` is unavailable under
        // Swift concurrency.
        let captured = OSAllocatedUnfairLock<[Clear.ExitPlan]>(initialState: [])
        Clear.exitHook = { plan in
            captured.withLock { $0.append(plan) }
        }
        defer { Clear.exitHook = nil }

        // Build a Clear command that runs the orchestration against
        // a fake center, then exits via the hook. `Clear.run`
        // hard-codes `UNUserNotificationCenter.current()`, which is
        // a live system handle in tests — that's fine because the
        // hook short-circuits before any sleep, and the underlying
        // `removeAll*` calls are fire-and-forget no-ops on a test
        // host with no posted notifications.
        let cmd = try Clear.parse([])
        try await cmd.run()

        let plans = captured.withLock { $0 }
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(
            plans.first,
            Clear.ExitPlan(drain: RoarAppDelegate.exitDrainDelay, code: 0),
            "Default `clear` must drain `exitDrainDelay` (XPC ack "
            + "window) and exit 0."
        )
    }

    /// `Clear.run --categories` alone: orchestration is the prune
    /// path; the post-orchestration drain at the call site is
    /// still `exitDrainDelay` (the prune wrote a category set,
    /// which is the same XPC-ack hazard the removes face), exit
    /// code 0. Pin the drain so a refactor that uses zero on the
    /// prune-only path doesn't slip past.
    func testRunCategoriesOnlyDrainAndExit() async throws {
        let captured = OSAllocatedUnfairLock<[Clear.ExitPlan]>(initialState: [])
        Clear.exitHook = { plan in
            captured.withLock { $0.append(plan) }
        }
        defer { Clear.exitHook = nil }

        let cmd = try Clear.parse(["--categories"])
        try await cmd.run()

        let plans = captured.withLock { $0 }
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(
            plans.first,
            Clear.ExitPlan(drain: RoarAppDelegate.exitDrainDelay, code: 0)
        )
    }

    /// Concurrent-send preservation: simulate snapshot 1 observing
    /// no categories and snapshot 2 observing a freshly-registered
    /// dynamic category with a pending notification, AND a stale
    /// dynamic category that the prune SHOULD drop. The stale
    /// entry forces `kept != categories2` so the skip-write check
    /// does NOT short-circuit — the orchestrator must call
    /// `setNotificationCategories` AND the call's argument must
    /// contain the concurrently-added category.
    ///
    /// Without the stale entry the previous shape of this test
    /// allowed the skip-write branch to satisfy the assertion (the
    /// "if `lastWrittenCategories` exists, check it" guard fell
    /// through when the orchestrator never wrote at all), which
    /// meant a regression in `mergePrunedCategories` that always
    /// produced the snapshot-2 value would pass the test even
    /// though the merge had clobbered nothing only because there
    /// was nothing to merge.
    ///
    /// This is the integration test for Fix #2 — the pure logic is
    /// covered by `CategoryPruneMergeTests`, but only the
    /// orchestration through `pruneUnreferencedDynamicCategories`
    /// proves the second snapshot is actually read at the right
    /// point in time.
    func testConcurrentSendDoesNotGetClobbered() async throws {
        let cmd = try parseClear(["--categories"])
        let fake = FakeClearCenter()
        // Snapshot 1: empty world.
        fake.seed(categories: [], delivered: [], pending: [])
        // Snapshot 2: a brand-new dynamic category appeared (with
        // a pending notification referencing it), AND a stale
        // dynamic category with no references. The stale entry
        // forces `kept` to differ from `categories2`, so the
        // skip-write check in `pruneUnreferencedDynamicCategories`
        // does NOT short-circuit and `setNotificationCategories`
        // is genuinely exercised.
        let newDyn = UNNotificationCategory(
            identifier: "roar.dyn.cafebabe",
            actions: [], intentIdentifiers: [], options: []
        )
        let staleDyn = UNNotificationCategory(
            identifier: "roar.dyn.deadbeef",
            actions: [], intentIdentifiers: [], options: []
        )
        // Build a pending request whose categoryIdentifier matches
        // the *new* category only. The stale category has no
        // referencing notification and must be pruned. The merge
        // looks at `request.content.categoryIdentifier`.
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "roar.dyn.cafebabe"
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        fake.seed(categories: [newDyn, staleDyn], delivered: [], pending: [request])

        try await cmd.runOrchestration(center: fake)

        // Assert unconditionally that the write happened — with
        // the stale entry, `kept != categories2` and the skip-
        // write branch cannot short-circuit. A regression in
        // `mergePrunedCategories` that lost the new category
        // would fail this assertion outright.
        let written = try XCTUnwrap(
            fake.lastWrittenCategories,
            "Expected setNotificationCategories to be called: a stale "
            + "dyn category forces kept != categories2, so the skip-"
            + "write check cannot short-circuit. If this is nil, the "
            + "orchestrator stopped re-reading the second snapshot."
        )
        XCTAssertTrue(
            written.contains(where: { $0.identifier == "roar.dyn.cafebabe" }),
            "Concurrent send's category was clobbered. Written: \(written.map { $0.identifier })"
        )
        XCTAssertFalse(
            written.contains(where: { $0.identifier == "roar.dyn.deadbeef" }),
            "Stale dyn category should have been pruned. Written: \(written.map { $0.identifier })"
        )
        // The double-snapshot guarantee: two category fetches must
        // have happened (one for each snapshot taken either side
        // of the async gap).
        let categoryFetchCount = fake.calls.filter { $0 == .fetchCategories }.count
        XCTAssertGreaterThanOrEqual(
            categoryFetchCount, 2,
            "Expected two category fetches (one per snapshot); got \(categoryFetchCount)"
        )
    }
}
