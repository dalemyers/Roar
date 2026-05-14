import XCTest
import ArgumentParser
@testable import roar

/// Pinned behaviour for `--wait-timeout` validation: must be a
/// duration in the same `<number><unit>` format as `--in`, and only
/// meaningful with `--wait`.
final class WaitTimeoutValidationTests: XCTestCase {

    func testNilAcceptedWithoutWait() throws {
        try Send.validateWaitTimeout(waitTimeout: nil, wait: false)
    }

    func testNilWithWaitSubstitutesDefault() throws {
        // The validator fills in `defaultWaitTimeoutSeconds` when
        // `--wait` is set but `--wait-timeout` is omitted, so a
        // forgotten timeout in CI can't hang the runner forever.
        let parsed = try Send.validateWaitTimeout(
            waitTimeout: nil, wait: true)
        XCTAssertEqual(parsed, Send.defaultWaitTimeoutSeconds)
    }

    func testValueWithoutWaitRejected() {
        XCTAssertThrowsError(
            try Send.validateWaitTimeout(waitTimeout: "30s", wait: false)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testValueWithWaitAccepted() throws {
        try Send.validateWaitTimeout(waitTimeout: "30s", wait: true)
        try Send.validateWaitTimeout(waitTimeout: "5m", wait: true)
        try Send.validateWaitTimeout(waitTimeout: "1h", wait: true)
    }

    func testMalformedValueRejected() {
        XCTAssertThrowsError(
            try Send.validateWaitTimeout(waitTimeout: "thirty", wait: true)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testBelowMinimumRejected() {
        XCTAssertThrowsError(
            try Send.validateWaitTimeout(waitTimeout: "0.1s", wait: true)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - Cached parse value

    /// Pin the contract that `validateWaitTimeout` returns the parsed
    /// `TimeInterval` so the await-site consumer doesn't have to
    /// re-parse the raw string. Pre-fix the consumer ran
    /// `parseScheduleInterval` again under `try? ... ?? 0`, which
    /// would silently disable the timeout (CI job hangs) if the two
    /// parsers ever drifted out of sync.
    func testReturnsParsedSecondsForValidInput() throws {
        let parsed = try Send.validateWaitTimeout(
            waitTimeout: "30s", wait: true)
        XCTAssertEqual(parsed, 30)
    }

    func testReturnsParsedSecondsForFractionalUnits() throws {
        let parsed = try Send.validateWaitTimeout(
            waitTimeout: "1.5m", wait: true)
        XCTAssertEqual(parsed, 90)
    }

    func testReturnsDefaultWhenFlagOmittedWithWait() throws {
        // Companion to `testNilWithWaitSubstitutesDefault` — pin that
        // the substitution lives in the validator (one source of
        // truth) rather than in the consumer.
        let parsed = try Send.validateWaitTimeout(
            waitTimeout: nil, wait: true)
        XCTAssertEqual(parsed, Send.defaultWaitTimeoutSeconds)
    }

    func testReturnsNilEvenWithoutWaitWhenFlagOmitted() throws {
        // `--wait` off + no `--wait-timeout` -> nil. The call site
        // doesn't consult the value in that branch, but returning nil
        // (rather than the 5min default) keeps the validator's
        // semantics honest: there's no timeout if there's no wait.
        let parsed = try Send.validateWaitTimeout(
            waitTimeout: nil, wait: false)
        XCTAssertNil(parsed)
    }

    /// End-to-end pin that the consumer uses the *cached* parsed
    /// value, not the raw `--wait-timeout` string. Drive the await
    /// site with a `TimeInterval?` directly — no string at all — and
    /// verify the timeout fires. If a future refactor reintroduces a
    /// `parseScheduleInterval` call in the consumer keyed on the raw
    /// string, the parameter list will no longer compile, and this
    /// test would fail to build along with the production path.
    @MainActor
    func testCachedIntervalDrivesTimeout() async {
        let delegate = RoarAppDelegate()
        delegate.enableWaitMode(forRequest: "test-wait-timeout-cached")
        // 500ms (not 50ms) to de-flake: a CI runner under load can
        // see Task.sleep wake significantly late, and the previous
        // 50ms budget was tight enough that scheduling jitter could
        // produce a misleading "timeout did not fire" failure when
        // the production code is correct. The proper fix is to inject
        // a virtual clock so the timeout fires deterministically
        // without wall-clock waiting — that's a Wave 5/H2 refactor;
        // for now, widening the window trades a few hundred ms of
        // suite time for stability.
        //
        // Lower-bound elapsed time also guards against the inverse
        // regression: a future change that nil-coalesces the cached
        // interval to 0 and fires `cancelWait` immediately would
        // pass the nil-response assertion but complete in <100ms.
        // Asserting the elapsed budget pins "the timeout actually
        // waited" alongside "the response was nil."
        let start = ContinuousClock.now
        let response = await Send.awaitResponseWithOptionalTimeout(
            delegate: delegate,
            timeoutSeconds: 0.5
        )
        let elapsed = ContinuousClock.now - start
        XCTAssertNil(response, "timeout should resume with nil")
        XCTAssertGreaterThanOrEqual(
            elapsed, .milliseconds(400),
            "timeout fired suspiciously early — cached interval may "
            + "have been mis-parsed to 0"
        )
    }
}
