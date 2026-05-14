import XCTest
import os
import UserNotifications
@testable import roar

/// Pin the contract that the `--wait` flow drains the UN XPC ack
/// before terminating. The non-wait path uses `scheduleExit`, which
/// detaches a Task that sleeps `exitDrainDelay` before `exit()`-ing
/// — that delay exists specifically to let `usernoted` flush the
/// XPC reply to the click ack, avoiding an "abandoned response"
/// log entry.
///
/// The `--wait` flow used to call `Darwin.exit(0)` immediately after
/// `print`-ing the terminal output, *not* using `scheduleExit`. The
/// XPC reply to the click ack — which fires inside the delegate's
/// `routeResponse` via `completionHandler()` — could be still in
/// flight when the process terminated. `formatWaitResponse` now
/// returns the drain duration alongside the output so the caller in
/// `Send.run` can sleep before exiting.
///
/// These tests cover both byte-level output layout and the drain
/// duration, since both are part of the public contract callers of
/// `roar send --wait` depend on (the output is what a shell script
/// captures; the drain is what guarantees usernoted ack delivery).
final class WaitExitDrainTests: XCTestCase {

    /// Defensive teardown: every test that installs `Send.exitHook`
    /// also registers a local `defer { ... = nil }`, but a throw
    /// before the `defer` line would leak the hook into the next
    /// test in the suite. Clearing unconditionally here is cheap and
    /// makes the suite robust to that whole class of regression.
    override func tearDown() {
        Send.exitHook = nil
        super.tearDown()
    }

    // MARK: - Drain duration

    /// The drain duration must be at least `RoarAppDelegate.exitDrainDelay`
    /// for every terminal click outcome. A weaker contract (e.g.
    /// "non-zero") would let a refactor silently shorten the drain
    /// to a value that races the XPC flush; pinning to the shared
    /// constant means a future tuning change in `RoarAppDelegate`
    /// automatically tracks here.
    func testDefaultActionDrainMatchesExitDrainDelay() {
        let outcome = Send.formatWaitResponse(
            actionIdentifier: Send.waitDefaultSentinel,
            userText: nil
        )
        XCTAssertEqual(outcome.drain, RoarAppDelegate.exitDrainDelay)
    }

    func testDismissActionDrainMatchesExitDrainDelay() {
        let outcome = Send.formatWaitResponse(
            actionIdentifier: Send.waitDismissSentinel,
            userText: nil
        )
        XCTAssertEqual(outcome.drain, RoarAppDelegate.exitDrainDelay)
    }

    // MARK: - Exit codes by outcome

    /// Default click maps to exit code 0 — the user engaged with the
    /// notification and the script should treat it as a success.
    func testDefaultActionExitsZero() {
        let outcome = Send.formatWaitResponse(
            actionIdentifier: Send.waitDefaultSentinel,
            userText: nil
        )
        XCTAssertEqual(outcome.exitCode, 0)
    }

    /// Dismiss maps to `waitDismissExitCode` (3) so shell scripts can
    /// distinguish "the user actively rejected" from the default
    /// click without parsing stdout. Pre-fix both outcomes shared
    /// exit code 0 and the distinction was stdout-only.
    func testDismissActionExitsWithDismissCode() {
        let outcome = Send.formatWaitResponse(
            actionIdentifier: Send.waitDismissSentinel,
            userText: nil
        )
        XCTAssertEqual(outcome.exitCode, Send.waitDismissExitCode)
        XCTAssertNotEqual(
            outcome.exitCode, 0,
            "Dismiss must NOT share exit code 0 with the default click."
        )
    }

    /// Custom action ids count as engagement, not rejection — exit
    /// 0. A `--action approve:Approve` button that the user clicked
    /// is the same shape of outcome as the default click.
    func testCustomActionExitsZero() {
        let outcome = Send.formatWaitResponse(
            actionIdentifier: "approve",
            userText: nil
        )
        XCTAssertEqual(outcome.exitCode, 0)
    }

    func testCustomActionDrainMatchesExitDrainDelay() {
        let outcome = Send.formatWaitResponse(
            actionIdentifier: "my-custom-action",
            userText: nil
        )
        XCTAssertEqual(outcome.drain, RoarAppDelegate.exitDrainDelay)
    }

    func testTextInputDrainMatchesExitDrainDelay() {
        // Text-input responses are still terminal clicks — the XPC
        // ack path is the same as the default-action path.
        let outcome = Send.formatWaitResponse(
            actionIdentifier: Send.waitDefaultSentinel,
            userText: "user typed reply"
        )
        XCTAssertEqual(outcome.drain, RoarAppDelegate.exitDrainDelay)
    }

    // MARK: - Output bytes

    /// The default-action sentinel must serialise to `"default\n"`
    /// — what `roar send --wait` shell consumers branch on.
    /// Apple's `UNNotificationDefaultActionIdentifier` is a
    /// reverse-DNS string; surfacing it raw would be brittle if
    /// Apple ever renames it, so the wait path maps to the short
    /// sentinel documented in `--wait`'s help text. The mapping
    /// now lives in `printableActionID` (the call site in
    /// `exitFromWait` invokes it before passing the label into
    /// `formatWaitResponse`); this test pins `waitDefaultSentinel`'s
    /// expected printed shape.
    func testDefaultActionPrintsShortSentinel() {
        let outcome = Send.formatWaitResponse(
            actionIdentifier: Send.waitDefaultSentinel,
            userText: nil
        )
        XCTAssertEqual(outcome.output, "default\n")
    }

    func testDismissActionPrintsShortSentinel() {
        let outcome = Send.formatWaitResponse(
            actionIdentifier: Send.waitDismissSentinel,
            userText: nil
        )
        XCTAssertEqual(outcome.output, "dismiss\n")
    }

    func testCustomActionPrintsItsOwnIdentifier() {
        // Custom action ids pass through verbatim — the action id is
        // already screened by `parseActions` for whitespace and
        // control characters at send time.
        let outcome = Send.formatWaitResponse(
            actionIdentifier: "approve",
            userText: nil
        )
        XCTAssertEqual(outcome.output, "approve\n")
    }

    func testTextInputUserTextFollowsActionIDOnSecondLine() {
        let outcome = Send.formatWaitResponse(
            actionIdentifier: "reply",
            userText: "looks good"
        )
        XCTAssertEqual(outcome.output, "reply\nlooks good\n")
    }

    /// Text-input replies can contain embedded newlines; receivers
    /// should read until EOF rather than line-by-line. Pin that the
    /// helper does NOT sanitise — it emits the user's text verbatim.
    func testTextInputPreservesEmbeddedNewlines() {
        let outcome = Send.formatWaitResponse(
            actionIdentifier: "reply",
            userText: "line one\nline two"
        )
        XCTAssertEqual(outcome.output, "reply\nline one\nline two\n")
    }

    /// Nil `userText` (a plain default/dismiss response, not a
    /// text-input response) must NOT emit a trailing empty line.
    /// Consumers branching on "two lines vs one" would otherwise
    /// misclassify the default click.
    func testNilUserTextEmitsSingleLine() {
        let outcome = Send.formatWaitResponse(
            actionIdentifier: Send.waitDefaultSentinel,
            userText: nil
        )
        XCTAssertFalse(outcome.output.contains("\n\n"))
        let lineCount = outcome.output.split(
            separator: "\n", omittingEmptySubsequences: false
        ).count
        // "default\n" -> ["default", ""] -> count 2
        XCTAssertEqual(lineCount, 2)
    }

    /// Empty (not nil) user text — a `UNTextInputNotificationResponse`
    /// where the user submitted an empty reply — must still produce a
    /// trailing newline so the receiver sees the "text was present"
    /// signal even though the text was empty. The contract is "two
    /// lines for text-input, one line for plain"; an empty reply is
    /// still text-input.
    func testEmptyUserTextEmitsTrailingNewline() {
        let outcome = Send.formatWaitResponse(
            actionIdentifier: "reply",
            userText: ""
        )
        XCTAssertEqual(outcome.output, "reply\n\n")
    }

    // MARK: - Exit hook (call-site pinning)

    /// Drive `Send.exitFromWait` with a matched-click primitive and
    /// pin the `ExitPlan` that lands at `performExit`. The drain
    /// must be `exitDrainDelay` and the exit code 0 — every byte
    /// of the call-site recipe a refactor could regress (e.g.
    /// dropping the post-print sleep, swapping the exit code from
    /// 0 to 1) is captured in the plan.
    ///
    /// The hook is cleared via `defer` so leakage doesn't poison
    /// downstream tests.
    /// `exitFromWait` for a dismiss primitive must produce the
    /// dismiss-specific exit plan. This mirrors `testExitFromWaitMatchedClickHook`
    /// but pins the new exit-code branch so a refactor that drops
    /// the dismiss code (e.g. nukes `WaitTerminalOutcome.exitCode`
    /// in favour of a hardcoded 0) fails here, not just in
    /// `formatWaitResponse`'s unit test.
    func testExitFromWaitDismissHook() async {
        let captured = OSAllocatedUnfairLock<[Send.ExitPlan]>(initialState: [])
        Send.exitHook = { plan in
            captured.withLock { $0.append(plan) }
        }
        defer { Send.exitHook = nil }

        await Send.exitFromWait(
            primitives: Send.WaitExitPrimitives(
                actionIdentifier: Send.waitDismissSentinel,
                userText: nil
            )
        )

        let plans = captured.withLock { $0 }
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(
            plans.first,
            Send.ExitPlan(
                drain: RoarAppDelegate.exitDrainDelay,
                code: Send.waitDismissExitCode
            ),
            "Dismiss branch must exit \(Send.waitDismissExitCode), not 0."
        )
    }

    func testExitFromWaitMatchedClickHook() async {
        // `OSAllocatedUnfairLock` instead of `NSLock` because the
        // hook is invoked from an async context and `NSLock.lock`
        // is unavailable from async under the project's Swift
        // concurrency settings. The lock is Sendable, so it can
        // close over into the `@Sendable` hook safely.
        let captured = OSAllocatedUnfairLock<[Send.ExitPlan]>(initialState: [])
        Send.exitHook = { plan in
            captured.withLock { $0.append(plan) }
        }
        defer { Send.exitHook = nil }

        await Send.exitFromWait(
            primitives: Send.WaitExitPrimitives(
                actionIdentifier: Send.waitDefaultSentinel,
                userText: nil
            )
        )

        let plans = captured.withLock { $0 }
        XCTAssertEqual(plans.count, 1, "Hook fires exactly once")
        XCTAssertEqual(
            plans.first,
            Send.ExitPlan(drain: RoarAppDelegate.exitDrainDelay, code: 0),
            "Matched-click branch must drain `exitDrainDelay` (the "
            + "UN XPC ack window) and exit 0."
        )
    }

    /// Timeout branch — `nil` primitives signal `cancelWait()`
    /// fired. The drain MUST be zero (the timeout path never
    /// invoked a UN completion handler, so there is no XPC reply
    /// to flush) and the exit code is `waitTimeoutExitCode`
    /// (documented at `2`) so shell consumers can branch on it.
    /// A regression that drained anyway would tack 100ms onto
    /// every timeout exit, and a regression that swapped the exit
    /// code would silently rebrand a timeout as success.
    func testExitFromWaitTimeoutHook() async {
        let captured = OSAllocatedUnfairLock<[Send.ExitPlan]>(initialState: [])
        Send.exitHook = { plan in
            captured.withLock { $0.append(plan) }
        }
        defer { Send.exitHook = nil }

        await Send.exitFromWait(primitives: nil)

        let plans = captured.withLock { $0 }
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(
            plans.first,
            Send.ExitPlan(drain: .zero, code: Send.waitTimeoutExitCode),
            "Timeout branch must NOT drain (no UN ack in flight) and "
            + "must exit \(Send.waitTimeoutExitCode)."
        )
    }
}
