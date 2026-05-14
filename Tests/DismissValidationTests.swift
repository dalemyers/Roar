import XCTest
import ArgumentParser
import os
@testable import roar

/// Pinned behaviour for `Dismiss.validateIdentifiers`. UN silently
/// no-ops on empty/whitespace identifiers; the validator catches that
/// up-front so the user gets a clear error rather than a silent
/// "nothing happened."
final class DismissValidationTests: XCTestCase {

    /// Defensive teardown: even though every individual test that
    /// mutates `Dismiss.exitHook` registers a local `defer { ... = nil }`,
    /// a throw before the `defer` line (e.g. an XCTFail in setup, or
    /// a test that's reordered to install the hook before the
    /// `defer`) would leak the hook into the next test in the suite.
    /// Clearing unconditionally here is cheap and makes the suite
    /// robust to that whole class of test-isolation regression.
    override func tearDown() {
        Dismiss.exitHook = nil
        super.tearDown()
    }

    func testNonEmptyAccepted() throws {
        try Dismiss.validateIdentifiers(["abc"])
        try Dismiss.validateIdentifiers(["abc", "def"])
    }

    func testEmptyArrayRejected() {
        XCTAssertThrowsError(try Dismiss.validateIdentifiers([])) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testEmptyStringRejected() {
        XCTAssertThrowsError(try Dismiss.validateIdentifiers([""])) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testWhitespaceOnlyRejected() {
        XCTAssertThrowsError(try Dismiss.validateIdentifiers(["   "])) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testValidIdsWithOneEmptyRejected() {
        // The presence of one bad id taints the whole call — UN's
        // remove APIs operate on the array as a unit.
        XCTAssertThrowsError(
            try Dismiss.validateIdentifiers(["abc", "", "def"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    /// A hand-typed `dismiss "foo\0bar"` would truncate at the XPC
    /// C-string bridge — `usernoted` would see `"foo"` and either
    /// silently no-op or, worse, remove a different notification
    /// whose identifier happens to match the truncated prefix.
    /// `validateIdentifiers` mirrors the NUL/control-char screening
    /// applied to `--identifier` at send time so the asymmetry can't
    /// be exploited from the dismiss side.
    func testDismissRejectsNULInIdentifier() {
        XCTAssertThrowsError(
            try Dismiss.validateIdentifiers(["foo\0bar"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - Orchestration + exit hook (call-site pinning)

    /// Captures the remove-delivered / remove-pending sequence and
    /// the snapshot fetches the orchestrator now performs so a
    /// regression in the unknown-id reporting (or the remove order)
    /// fails loudly here. The fake also lets tests seed the
    /// "currently-known" set so unknown-id behaviour is observable
    /// without standing up the real UN center.
    final class FakeDismissCenter: Dismiss.DismissCenter {
        enum Call: Equatable {
            case fetchDelivered
            case fetchPending
            case removeDelivered([String])
            case removePending([String])
        }
        private(set) var calls: [Call] = []
        var deliveredIDs: [String] = []
        var pendingIDs: [String] = []

        func removeDeliveredNotifications(withIdentifiers ids: [String]) {
            calls.append(.removeDelivered(ids))
        }
        func removePendingNotificationRequests(withIdentifiers ids: [String]) {
            calls.append(.removePending(ids))
        }
        func deliveredIdentifiersAsync() async -> [String] {
            calls.append(.fetchDelivered)
            return deliveredIDs
        }
        func pendingIdentifiersAsync() async -> [String] {
            calls.append(.fetchPending)
            return pendingIDs
        }
    }

    /// Orchestration snapshots both buckets first, then calls BOTH
    /// remove APIs with the same id list. Pin the order so a
    /// refactor that drops one branch (e.g. "pending no longer
    /// needed") fails loudly.
    func testOrchestrationCallsBothBuckets() async throws {
        let cmd = try Dismiss.parse(["abc", "def"])
        let fake = FakeDismissCenter()
        // Seed the pending bucket so the ids match — otherwise the
        // exit-code path would flip to noMatch. The remove-order
        // contract is independent of match/no-match.
        fake.pendingIDs = ["abc", "def"]
        _ = try await cmd.runOrchestration(center: fake)
        // Snapshots come first (in either order), then the two
        // remove calls in delivered-then-pending order.
        XCTAssertTrue(
            fake.calls.contains(.fetchDelivered),
            "Expected delivered snapshot; got \(fake.calls)"
        )
        XCTAssertTrue(
            fake.calls.contains(.fetchPending),
            "Expected pending snapshot; got \(fake.calls)"
        )
        // `XCTUnwrap` both at once and assert on the unwrapped Ints
        // — the previous shape XCTAssertNotNil'd separately and then
        // force-unwrapped, which the lint policy flags. Collapsing
        // to `XCTUnwrap` keeps the failure messages clear (the
        // unwrap surfaces the missing-call case) and lets the
        // `LessThan` comparison work on non-optional values.
        let removeDeliveredIdx = try XCTUnwrap(
            fake.calls.firstIndex(of: .removeDelivered(["abc", "def"])),
            "Expected removeDelivered call; got \(fake.calls)"
        )
        let removePendingIdx = try XCTUnwrap(
            fake.calls.firstIndex(of: .removePending(["abc", "def"])),
            "Expected removePending call; got \(fake.calls)"
        )
        XCTAssertLessThan(
            removeDeliveredIdx, removePendingIdx,
            "Dismiss must hit delivered before pending; got \(fake.calls)"
        )
    }

    /// When every supplied id matches a known pending notification,
    /// `runOrchestration` returns an empty unknowns array. The
    /// happy-path exit code is 0.
    func testOrchestrationReturnsEmptyWhenAllMatch() async throws {
        let cmd = try Dismiss.parse(["abc", "def"])
        let fake = FakeDismissCenter()
        fake.pendingIDs = ["abc", "def", "other"]
        let unknowns = try await cmd.runOrchestration(center: fake)
        XCTAssertEqual(unknowns, [], "All ids should match — got unknowns \(unknowns)")
    }

    /// When NO supplied id matches anything in either bucket, every
    /// id is reported as unknown. Ids preserve the user's argv order
    /// so the stderr report names them in the order they were typed.
    func testOrchestrationReturnsAllUnknownsWhenNoneMatch() async throws {
        let cmd = try Dismiss.parse(["typo-1", "typo-2"])
        let fake = FakeDismissCenter()
        fake.pendingIDs = ["something-else"]
        let unknowns = try await cmd.runOrchestration(center: fake)
        XCTAssertEqual(
            unknowns, ["typo-1", "typo-2"],
            "Expected both typos reported in argv order; got \(unknowns)"
        )
    }

    /// Mixed case: some ids match, some don't. Only the unknowns
    /// come back; the matching id is silent in the report.
    func testOrchestrationReturnsOnlyUnmatchedIDs() async throws {
        let cmd = try Dismiss.parse(["good", "typo"])
        let fake = FakeDismissCenter()
        fake.pendingIDs = ["good", "bystander"]
        let unknowns = try await cmd.runOrchestration(center: fake)
        XCTAssertEqual(unknowns, ["typo"])
    }

    /// Duplicate typos are reported once — the user passed the same
    /// id twice (likely a copy-paste mistake), and surfacing it
    /// twice in the warning is noise.
    func testOrchestrationDedupesUnknowns() async throws {
        let cmd = try Dismiss.parse(["typo", "typo"])
        let fake = FakeDismissCenter()
        fake.pendingIDs = []
        let unknowns = try await cmd.runOrchestration(center: fake)
        XCTAssertEqual(unknowns, ["typo"])
    }

    /// `Dismiss.run` happy path: id matches a pending notification,
    /// exit 0 with the `exitDrainDelay` drain. The `Darwin.exit`
    /// itself is suppressed by the hook; the captured plan is the
    /// regression backstop for the call-site sleep+exit.
    ///
    /// Driven through `runOrchestration` rather than `run()` so the
    /// test doesn't depend on the live `UNUserNotificationCenter`'s
    /// state — under XCTest there are no real notifications, so
    /// `run()` would always hit the noMatch branch and pin the
    /// wrong exit code.
    func testRunDrainAndExitOnMatch() async throws {
        // `OSAllocatedUnfairLock` because the hook fires from an
        // async context.
        let captured = OSAllocatedUnfairLock<[Dismiss.ExitPlan]>(initialState: [])
        Dismiss.exitHook = { plan in
            captured.withLock { $0.append(plan) }
        }
        defer { Dismiss.exitHook = nil }

        let cmd = try Dismiss.parse(["some-id"])
        let fake = FakeDismissCenter()
        fake.pendingIDs = ["some-id"]
        let unknowns = try await cmd.runOrchestration(center: fake)
        // Mirror the exit-code computation `run()` performs so this
        // test pins the contract end-to-end (orchestration + exit
        // hook + match-rate decision) without depending on the
        // real UN center.
        let plan = Dismiss.ExitPlan(
            drain: RoarAppDelegate.exitDrainDelay,
            code: Dismiss.exitCode(
                unknownIDs: unknowns, requested: cmd.identifiers)
        )
        if let hook = Dismiss.exitHook {
            await hook(plan)
        }

        let plans = captured.withLock { $0 }
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(
            plans.first,
            Dismiss.ExitPlan(drain: RoarAppDelegate.exitDrainDelay, code: 0),
            "Matched-id `dismiss` must drain `exitDrainDelay` and exit 0."
        )
    }

    /// Regression: `roar dismiss foo foo` against an unknown "foo"
    /// must exit `noMatchExitCode`, not 0. The orchestration
    /// de-duplicates the typo in its returned unknowns array, so a
    /// naïve `unknowns.count == requested.count` (the historical
    /// computation) compares `1 == 2` and concludes "some matched"
    /// — even though nothing was dismissed. Scripts that branch on
    /// `$?` to detect typos saw a silent false success in this case.
    /// `Dismiss.exitCode` performs the de-duplicated set comparison
    /// that answers the real question.
    func testExitCodeAllUnknownWithDuplicatesReturnsNoMatch() {
        XCTAssertEqual(
            Dismiss.exitCode(unknownIDs: ["foo"], requested: ["foo", "foo"]),
            Dismiss.noMatchExitCode,
            "All-unknown invocation with duplicate argv ids must still "
            + "return noMatchExitCode, not 0."
        )
    }

    /// Companion to the duplicate-unknown regression: when at least
    /// one DISTINCT id matched (delivered or pending) the exit code
    /// must be 0 even if there are also unknowns. The set comparison
    /// is asymmetric: unknowns ⊊ requested means "some matched".
    func testExitCodeSomeMatchedReturnsZero() {
        XCTAssertEqual(
            Dismiss.exitCode(
                unknownIDs: ["typo"],
                requested: ["good", "typo"]),
            0
        )
    }

    /// Empty unknowns (every id matched) — exit 0.
    func testExitCodeAllMatchedReturnsZero() {
        XCTAssertEqual(
            Dismiss.exitCode(unknownIDs: [], requested: ["a", "b"]),
            0
        )
    }

    /// All distinct ids unknown without duplicates — exit noMatch.
    func testExitCodeAllUnknownReturnsNoMatch() {
        XCTAssertEqual(
            Dismiss.exitCode(
                unknownIDs: ["a", "b"], requested: ["a", "b"]),
            Dismiss.noMatchExitCode
        )
    }

    /// `Dismiss.run` no-match path: every supplied id is unknown,
    /// so the exit code is `noMatchExitCode` (4) — distinct from
    /// the matched-id success and from ArgumentParser's usage error.
    func testRunExitsNonZeroWhenNothingMatches() async throws {
        let captured = OSAllocatedUnfairLock<[Dismiss.ExitPlan]>(initialState: [])
        Dismiss.exitHook = { plan in
            captured.withLock { $0.append(plan) }
        }
        defer { Dismiss.exitHook = nil }

        let cmd = try Dismiss.parse(["typo-id"])
        let fake = FakeDismissCenter()
        // No pending/delivered entries — every id is unknown.
        let unknowns = try await cmd.runOrchestration(center: fake)
        let plan = Dismiss.ExitPlan(
            drain: RoarAppDelegate.exitDrainDelay,
            code: Dismiss.exitCode(
                unknownIDs: unknowns, requested: cmd.identifiers)
        )
        if let hook = Dismiss.exitHook {
            await hook(plan)
        }

        let plans = captured.withLock { $0 }
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(
            plans.first,
            Dismiss.ExitPlan(
                drain: RoarAppDelegate.exitDrainDelay,
                code: Dismiss.noMatchExitCode),
            "All-unknown `dismiss` must exit \(Dismiss.noMatchExitCode), "
            + "not 0 — otherwise scripts cannot distinguish 'I deleted "
            + "what I asked for' from 'my id was wrong'."
        )
    }
}
