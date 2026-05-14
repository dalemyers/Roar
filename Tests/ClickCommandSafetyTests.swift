import XCTest
@testable import roar

/// Pin the click-time NUL-byte guard on `roar.exec.command`. The send-time
/// validator (`Send.validateExecOptIn`) already rejects NUL in
/// `--exec`, but the *click-time* check in `ShellExecutor`
/// is the actual security boundary against userInfo spoofed by any
/// process posting under the same bundle id — that's the path that
/// matters most to lock down with tests.
///
/// `posix_spawn` argv is built via `strdup`, which truncates Swift
/// strings at the first NUL. A hostile sender posting
/// `roar.exec.command = "echo ok\0; rm -rf $HOME"` would have the visible
/// debug-logged value diverge from the bytes the shell actually sees.
/// Reject NUL on the click side so what the user inspects is what runs.
final class ClickCommandSafetyTests: XCTestCase {

    func testCleanCommandIsSafe() {
        XCTAssertTrue(
            ShellExecutor.isClickCommandSafe("echo hello"))
    }

    func testEmptyCommandIsSafe() {
        // Empty isn't useful, but it's not a NUL-truncation hazard;
        // policy is "rejection iff NUL," and the empty string has no
        // NUL bytes. Other rejection paths (opt-in missing, empty
        // command via shell) are handled elsewhere.
        XCTAssertTrue(ShellExecutor.isClickCommandSafe(""))
    }

    func testCommandWithMidNULIsUnsafe() {
        XCTAssertFalse(
            ShellExecutor.isClickCommandSafe("echo ok\u{0000}; rm -rf /tmp/x"))
    }

    func testCommandWithLeadingNULIsUnsafe() {
        XCTAssertFalse(
            ShellExecutor.isClickCommandSafe("\u{0000}echo ok"))
    }

    func testCommandWithTrailingNULIsUnsafe() {
        XCTAssertFalse(
            ShellExecutor.isClickCommandSafe("echo ok\u{0000}"))
    }

    /// Newlines and other control characters that aren't NUL are
    /// *allowed* — the shell is the right layer to interpret those,
    /// and the user opted into shell-on-click. The check is
    /// specifically about NUL because only NUL trips strdup
    /// truncation.
    func testCommandWithNewlineIsSafe() {
        XCTAssertTrue(
            ShellExecutor.isClickCommandSafe("echo a\necho b"))
    }

    /// `exitDrainDelay` is shared between `RoarAppDelegate`,
    /// `Clear.run`, and `Dismiss.run` — all three call fire-and-
    /// forget UN APIs whose XPC reply has the same flush-race
    /// semantics. Pin the current value so a future tuning change
    /// is visible in test diffs (and so any callsite drift back to
    /// a hardcoded literal would fail this test alongside the
    /// drift).
    ///
    /// 100ms is several orders of magnitude larger than the actual
    /// XPC round-trip on a healthy system; tightening it requires
    /// empirical measurement of `usernoted` ack timing under load,
    /// not a casual edit.
    func testExitDrainDelayIs100Milliseconds() {
        XCTAssertEqual(RoarAppDelegate.exitDrainDelay, .milliseconds(100))
    }
}
