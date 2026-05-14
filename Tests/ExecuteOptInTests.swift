import XCTest
import ArgumentParser
@testable import roar

/// Pin the policy that `--exec` requires an explicit
/// `--allow-shell-on-click` acknowledgement. The notification body is
/// independent of the executed command, so without this gate a
/// "Build complete" notification could silently run an attacker-supplied
/// shell payload on click.
final class ExecuteOptInTests: XCTestCase {

    func testNoExecuteIsAlwaysFine() throws {
        // Absent --exec, the opt-in flag is irrelevant.
        try Send.validateExecOptIn(exec: nil, allowShellOnClick: false)
        try Send.validateExecOptIn(exec: nil, allowShellOnClick: true)
    }

    func testExecuteWithoutOptInThrows() {
        XCTAssertThrowsError(
            try Send.validateExecOptIn(exec: "echo hi", allowShellOnClick: false)
        ) { error in
            XCTAssertTrue(
                error is ValidationError,
                "Expected ValidationError, got \(type(of: error)): \(error)"
            )
        }
    }

    func testExecuteWithOptInPasses() throws {
        try Send.validateExecOptIn(exec: "echo hi", allowShellOnClick: true)
    }

    /// Empty `--exec ""` is rejected outright, regardless of
    /// opt-in. The click handler would otherwise run
    /// `/bin/sh -c "cd ...; "` (a no-op shell) and consume the
    /// opt-in for nothing. Worse, a same-bundle-id spoofer could
    /// use the no-op as a click-detection oracle. Both opt-in
    /// states must throw — the rejection is on the *value*, not on
    /// the policy.
    func testEmptyExecuteWithoutOptInThrows() {
        XCTAssertThrowsError(
            try Send.validateExecOptIn(exec: "", allowShellOnClick: false)
        ) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testEmptyExecuteWithOptInAlsoThrows() {
        XCTAssertThrowsError(
            try Send.validateExecOptIn(exec: "", allowShellOnClick: true)
        ) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    /// `posix_spawn`'s argv is built via `strdup`, which truncates a
    /// Swift String at the first NUL byte. A `--exec` value
    /// containing NUL would therefore silently run a *different*
    /// command than the user sees — the visible string includes
    /// everything past the NUL, but the executed string is the
    /// prefix only. Reject NUL up-front so what's seen is what runs.
    func testExecuteWithNULByteThrowsEvenWithOptIn() {
        XCTAssertThrowsError(
            try Send.validateExecOptIn(
                exec: "echo ok\u{0000}; rm -rf /tmp/x",
                allowShellOnClick: true)
        ) { error in
            XCTAssertTrue(
                error is ValidationError,
                "Expected ValidationError, got \(type(of: error)): \(error)"
            )
        }
    }

    /// NUL at the start of the command also rejects — covers the
    /// reversed-truncation attack where the visible value is the
    /// post-NUL trailer.
    func testExecuteWithLeadingNULByteThrows() {
        XCTAssertThrowsError(
            try Send.validateExecOptIn(
                exec: "\u{0000}echo ok",
                allowShellOnClick: true)
        )
    }

    /// NUL rejection runs regardless of opt-in state. The user can't
    /// "opt in" to silently-divergent command execution.
    func testExecuteWithNULByteThrowsWithoutOptIn() {
        XCTAssertThrowsError(
            try Send.validateExecOptIn(
                exec: "echo ok\u{0000}",
                allowShellOnClick: false)
        )
    }
}
