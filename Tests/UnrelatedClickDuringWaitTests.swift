import XCTest
import os
import UserNotifications
@testable import roar

/// Pin the routing rule for a click on a non-target notification
/// while a `--wait` is active.
///
/// Pre-fix behaviour: `routeResponse` fell through to
/// `handleActivation` → `scheduleExit(0)` whenever the click's
/// identifier didn't match `waitIdentifier`. That killed the parent
/// `--wait` invocation with exit 0 and no stdout while
/// `Send.run` was still awaiting its target identifier's response.
///
/// Post-fix behaviour: the delegate acks the click (so the
/// framework's response-handler watchdog doesn't log an abandoned
/// response) but does NOT activate / exec / open and does NOT
/// schedule exit. The wait stays parked; the target notification's
/// eventual click resumes the continuation.
final class UnrelatedClickDuringWaitTests: XCTestCase {

    // MARK: - Classification

    /// No wait is active → classifier reports `.notInWaitMode` and
    /// does NOT call the completion handler. The standard activate/
    /// exec/open path (the normal click-handler relaunch flow) owns
    /// the ack in that case.
    @MainActor
    func testNoWaitYieldsNotInWaitMode() {
        let delegate = RoarAppDelegate()
        var completionCalled = 0
        let classification = delegate.classifyAndConsumeWaitClick(
            receivedIdentifier: "any-id",
            matchedResponse: nil,
            completionHandler: { completionCalled += 1 }
        )
        XCTAssertEqual(classification, .notInWaitMode)
        XCTAssertEqual(
            completionCalled, 0,
            "no-wait branch must defer the ack to the downstream router"
        )
    }

    /// Wait active for `"A"`, click for `"B"` → classifier reports
    /// `.unrelatedDuringWait`, acks the framework, and leaves the
    /// continuation intact.
    ///
    /// "Still suspended" is verified by sleeping past the point a
    /// resumed continuation would have delivered to a probe Task,
    /// and then asserting the probe Task is not yet finished. We
    /// can't `await awaiter.value` directly to test this — a stuck
    /// awaiter would block the test forever — so the probe Task
    /// publishes its completion state via a `OSAllocatedUnfairLock`
    /// the test can poll without blocking.
    @MainActor
    func testUnrelatedClickAcksButDoesNotResumeContinuation() async {
        let delegate = RoarAppDelegate()
        delegate.enableWaitMode(forRequest: "A")

        // The probe publishes a `true` flag when the awaiter
        // resumes. Reading the flag from the test (after a sleep
        // long enough to cover any spurious resume) is non-blocking,
        // so a stuck awaiter doesn't hang the test.
        let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
        let awaiter = Task { @MainActor in
            let value = await delegate.awaitNextResponse()
            resumed.withLock { $0 = true }
            return value
        }
        // Yield briefly so the awaiter's `withCheckedContinuation`
        // installs `waitContinuation` before we deliver the click.
        try? await Task.sleep(for: .milliseconds(50))

        var completionCalled = 0
        let classification = delegate.classifyAndConsumeWaitClick(
            receivedIdentifier: "B",
            matchedResponse: nil,
            completionHandler: { completionCalled += 1 }
        )

        XCTAssertEqual(classification, .unrelatedDuringWait)
        XCTAssertEqual(
            completionCalled, 1,
            "framework watchdog ack is mandatory — the delegate is the "
            + "only entity that knows the click was received, and skipping "
            + "the ack would let `usernoted` log the response as abandoned"
        )

        // Cover any spurious resume — generously sized relative to
        // the synchronous bookkeeping `classifyAndConsumeWaitClick`
        // performs (microseconds). A 100ms window is far more than
        // any Task hop would take.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(
            resumed.withLock { $0 },
            "unrelated click must NOT resume the wait — the wait was "
            + "scoped to 'A', the click was for 'B'"
        )

        // Tear down via the documented `cancelWait` path so the
        // awaiter resolves and the test exits cleanly. Without this,
        // the awaiter would leak past the test boundary.
        delegate.cancelWait()
        let resolved = await awaiter.value
        XCTAssertNil(
            resolved,
            "after `cancelWait`, the awaiter resumes with nil — same "
            + "behaviour as the `--wait-timeout` teardown"
        )
        XCTAssertTrue(
            resumed.withLock { $0 },
            "after `cancelWait` resolves, the awaiter's resume hook "
            + "should have set the flag"
        )
    }

    /// The unrelated-click branch must NOT trigger `scheduleExit`.
    /// Pre-fix, the routing fell through to `handleActivation` /
    /// `handleNonActivationResponse`, both of which call
    /// `scheduleExit(0)` — that killed the wait's parent invocation
    /// with no output. The test seam `scheduleExitHook` counts
    /// calls so we can assert "zero exits scheduled" without
    /// actually exiting the test process.
    @MainActor
    func testUnrelatedClickDoesNotScheduleExit() async {
        let delegate = RoarAppDelegate()
        var exitCalls: [Int32] = []
        delegate.scheduleExitHook = { code in exitCalls.append(code) }
        delegate.enableWaitMode(forRequest: "target")

        _ = delegate.classifyAndConsumeWaitClick(
            receivedIdentifier: "stranger",
            matchedResponse: nil,
            completionHandler: { }
        )

        // Give any spurious `Task { exit() }` a window to fire.
        // `scheduleExit`'s real implementation sleeps `exitDrainDelay`
        // before exiting, which would not even fire in this hook
        // configuration — but the assertion is "the hook itself
        // wasn't invoked," which catches a regression where the
        // unrelated-click branch falls back through to the activate/
        // dismiss handlers.
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(
            exitCalls.isEmpty,
            "unrelated click during --wait must not schedule any exit; "
            + "got \(exitCalls)"
        )

        delegate.cancelWait()
    }

    /// Wait active for `"A"`, click for `"A"` with a buffered (nil)
    /// matched response → classifier resolves the matched-but-no-
    /// awaiter case by buffering. Tests the test-seam itself: a
    /// `nil` `matchedResponse` on the matched-identifier branch
    /// shouldn't crash, even though production callers always pass
    /// a real response.
    @MainActor
    func testMatchedIdentifierWithoutAwaiterDoesNotCrash() {
        let delegate = RoarAppDelegate()
        delegate.enableWaitMode(forRequest: "A")
        var completionCalled = 0
        let classification = delegate.classifyAndConsumeWaitClick(
            receivedIdentifier: "A",
            matchedResponse: nil,
            completionHandler: { completionCalled += 1 }
        )
        XCTAssertEqual(classification, .matchedWait)
        XCTAssertEqual(completionCalled, 1)
        // Buffer slot was empty because the test seam passed nil; the
        // defensive nil-guard in `classifyAndConsumeWaitClick` left
        // `pendingWaitResponse` unset rather than crashing.
        delegate.cancelWait()
    }

    /// Sanity check that `scheduleExitHook` is a settable property.
    /// The negative assertion in `testUnrelatedClickDoesNotScheduleExit`
    /// depends on the hook being assignable and observable; if a
    /// future refactor accidentally made `scheduleExitHook` private
    /// or `let`, the assignment in those tests would fail to compile
    /// — but a compile-time failure is friendlier than a runtime
    /// "always passing" test. This test pins both that the property
    /// is `var`-assignable from tests, and that direct invocation of
    /// the assigned closure works (which is the mechanism by which
    /// `scheduleExit` reaches it).
    @MainActor
    func testScheduleExitHookIsAssignableAndCallable() {
        let delegate = RoarAppDelegate()
        var captured: [Int32] = []
        delegate.scheduleExitHook = { code in captured.append(code) }
        delegate.scheduleExitHook?(42)
        XCTAssertEqual(captured, [42])
    }

    // MARK: - Claim flag interaction (regression for Wave 4 fix #C1)

    /// The Wave 3 unrelated-click-during-wait fix introduced a
    /// regression: `didReceive` set `claimed = true` on EVERY entry,
    /// so an unrelated click arriving before the awaited click
    /// poisoned the idempotency guard — the *awaited* click then
    /// hit the `alreadyClaimed` branch in `didReceive` and was
    /// silently dropped, and the wait hung until `--wait-timeout`
    /// expired (or forever absent a timeout).
    ///
    /// This test pins the post-fix shape: the claim flag must only
    /// flip on a TERMINAL classification (`.matchedWait` or
    /// `.notInWaitMode`), never on `.unrelatedDuringWait`. Drive
    /// the seam through the same claim-then-classify path that
    /// `didReceive` uses at runtime so a regression that re-claims
    /// on unrelated clicks fails this test.
    @MainActor
    func testUnrelatedClickDoesNotPoisonClaimFlag() {
        let delegate = RoarAppDelegate()
        delegate.enableWaitMode(forRequest: "A")

        // Deliver an unrelated click — should classify as
        // `.unrelatedDuringWait` and must NOT mark the click
        // claimed.
        let first = delegate.simulateDidReceiveForTests(
            receivedIdentifier: "B",
            completionHandler: { }
        )
        XCTAssertEqual(
            first.classification, .unrelatedDuringWait,
            "First click was for an unrelated identifier; expected "
            + ".unrelatedDuringWait, got \(String(describing: first.classification))"
        )
        XCTAssertFalse(
            first.idempotencyDropped,
            "Idempotency guard fired on first click — that means the "
            + "claim flag was set before the click even reached the "
            + "classifier."
        )

        // Now deliver the AWAITED click. With the C1 regression,
        // this would hit `alreadyClaimed` in `didReceive` and be
        // dropped without ever invoking the classifier — the
        // awaited wait would never resume and the process would
        // hang. Post-fix, the unrelated click did NOT claim, so
        // this click reaches the classifier and produces
        // `.matchedWait`.
        let second = delegate.simulateDidReceiveForTests(
            receivedIdentifier: "A",
            completionHandler: { }
        )
        XCTAssertFalse(
            second.idempotencyDropped,
            "Awaited click was dropped by the idempotency guard — the "
            + "unrelated click poisoned the claim flag. This is the "
            + "C1 regression."
        )
        XCTAssertEqual(
            second.classification, .matchedWait,
            "Awaited click should classify as .matchedWait once the "
            + "claim flag stayed clear past the unrelated click; got "
            + "\(String(describing: second.classification))"
        )

        delegate.cancelWait()
    }

    /// Mirror of the above for the no-wait path: a click delivered
    /// when `waitIdentifier` is nil falls through to
    /// `.notInWaitMode`, which IS terminal (the standard
    /// activate/exec/open pipeline owns the exit). The claim flag
    /// must be set on that branch so a framework re-delivery of
    /// the same click hits the idempotency guard. A regression
    /// that *fails* to claim on `.notInWaitMode` would let a
    /// double-delivered click double-`scheduleExit`.
    @MainActor
    func testNotInWaitModeStillClaimsForIdempotency() {
        let delegate = RoarAppDelegate()
        // No wait mode active.
        let first = delegate.simulateDidReceiveForTests(
            receivedIdentifier: "anything",
            completionHandler: { }
        )
        XCTAssertEqual(first.classification, .notInWaitMode)
        XCTAssertFalse(first.idempotencyDropped)

        // Same click delivered again — the framework occasionally
        // re-announces a response, and we must not let it
        // double-run the activate/exec/open side effects. Pin the
        // idempotency guard.
        let second = delegate.simulateDidReceiveForTests(
            receivedIdentifier: "anything",
            completionHandler: { }
        )
        XCTAssertTrue(
            second.idempotencyDropped,
            "Second delivery of a terminal click must short-circuit "
            + "via the claim idempotency guard."
        )
    }

}
