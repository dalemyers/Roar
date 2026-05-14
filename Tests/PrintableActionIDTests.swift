import XCTest
import UserNotifications
@testable import roar

/// Direct unit tests for `Send.printableActionID(actionIdentifier:)`,
/// the string-taking sibling that holds the actual mapping policy.
///
/// `UNNotificationResponse` is sealed (no public initialiser), which
/// previously meant the mapping was reachable only through the
/// `printableActionID(from:)` `from response:` overload — and that
/// overload couldn't be unit-tested without spinning up the full UN
/// runtime. The integration callers (`WaitExitDrainTests`) only saw
/// the *already-mapped* sentinel because the call site mapped first
/// and then passed the result into `formatWaitResponse`. A regression
/// that flipped the mapping to "always return
/// `response.actionIdentifier`" would have leaked Apple's reverse-DNS
/// constants (`com.apple.UNNotificationDefaultActionIdentifier`) to
/// shell consumers of `--wait` without any test catching it.
///
/// Splitting the function into the string-taking sibling closes that
/// gap. These tests pin the mapping policy directly.
final class PrintableActionIDTests: XCTestCase {

    /// Apple's default-action constant must collapse to the short
    /// `default` sentinel. Shell consumers of `roar send --wait`
    /// branch on this sentinel; the reverse-DNS form would force
    /// every `case` arm to match a long Apple-private string that
    /// could rename without warning.
    func testDefaultIdentifierMapsToShortSentinel() {
        let result = Send.printableActionID(
            actionIdentifier: UNNotificationDefaultActionIdentifier)
        XCTAssertEqual(result, Send.waitDefaultSentinel)
        XCTAssertEqual(result, "default")
    }

    /// Apple's dismiss-action constant must collapse to the short
    /// `dismiss` sentinel — same rationale as the default case.
    func testDismissIdentifierMapsToShortSentinel() {
        let result = Send.printableActionID(
            actionIdentifier: UNNotificationDismissActionIdentifier)
        XCTAssertEqual(result, Send.waitDismissSentinel)
        XCTAssertEqual(result, "dismiss")
    }

    /// A user-defined custom action id passes through verbatim.
    /// `parseActions` already screens custom ids for whitespace /
    /// control characters / reserved sentinels at send time, so
    /// the mapping helper has no further sanitisation to perform.
    func testCustomActionIDPassesThroughVerbatim() {
        XCTAssertEqual(
            Send.printableActionID(actionIdentifier: "approve"),
            "approve"
        )
    }

    /// Empty action identifier passes through verbatim — the
    /// mapping helper doesn't validate, just translates. This is
    /// the contract the call site relies on (validation happens
    /// upstream in `parseActions`).
    func testEmptyActionIDPassesThroughVerbatim() {
        XCTAssertEqual(
            Send.printableActionID(actionIdentifier: ""),
            ""
        )
    }

    /// A custom id that LOOKS like one of the short sentinels
    /// passes through unchanged — the mapping only collapses
    /// Apple's reverse-DNS constants, not the short labels.
    /// (Custom ids matching the sentinels would already have been
    /// refused upstream by `parseActions` as reserved, so in
    /// practice this never reaches the helper — but pinning the
    /// behaviour here means the helper stays self-contained and
    /// idempotent.)
    func testShortSentinelAsCustomIDPassesThroughVerbatim() {
        XCTAssertEqual(
            Send.printableActionID(actionIdentifier: "default"),
            "default"
        )
        XCTAssertEqual(
            Send.printableActionID(actionIdentifier: "dismiss"),
            "dismiss"
        )
    }
}
