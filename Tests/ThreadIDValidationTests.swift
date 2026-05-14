import XCTest
import ArgumentParser
@testable import roar

/// Pin the empty/whitespace rejection on `--thread-id`. Mirrors the same
/// shape as `--activate-bundle-id` validation: the UN framework would
/// otherwise accept the empty string silently and group nothing,
/// surprising the user.
final class ThreadIDValidationTests: XCTestCase {

    func testNilThreadIDIsAccepted() throws {
        try Send.validateThreadID(nil)
    }

    func testNormalThreadIDIsAccepted() throws {
        try Send.validateThreadID("build-results")
        try Send.validateThreadID("test")
        // Identifiers can contain any printable characters; the framework
        // treats them as opaque strings.
        try Send.validateThreadID("io.myers.roar/notifications#42")
    }

    func testEmptyThreadIDThrows() {
        XCTAssertThrowsError(try Send.validateThreadID("")) { error in
            XCTAssertTrue(error is ValidationError,
                          "Expected ValidationError, got \(type(of: error))")
        }
    }

    func testWhitespaceOnlyThreadIDThrows() {
        XCTAssertThrowsError(try Send.validateThreadID("   ")) { error in
            XCTAssertTrue(error is ValidationError)
        }
        XCTAssertThrowsError(try Send.validateThreadID("\t\n")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    /// NUL truncates at the XPC bridge — the visible thread id and the
    /// grouped-thread id would diverge silently. Reject up front.
    func testNULRejected() {
        XCTAssertThrowsError(try Send.validateThreadID("build\0results")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testNewlineRejected() {
        XCTAssertThrowsError(try Send.validateThreadID("build\nresults")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testEmbeddedTabRejected() {
        // Tab is a control character; the trimming pass only catches
        // surround-whitespace, not embedded.
        XCTAssertThrowsError(try Send.validateThreadID("build\tresults")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testESCRejected() {
        XCTAssertThrowsError(try Send.validateThreadID("build\u{001B}[2J")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    /// Length cap mirrors `--identifier`. UN's XPC surface accepts up
    /// to ~256 characters cleanly; longer values produce vague
    /// "internal error" responses from `add(_:)`.
    func testOverLengthRejected() {
        let over = String(repeating: "x", count: Send.maximumIdentifierLength + 1)
        XCTAssertThrowsError(try Send.validateThreadID(over)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testExactlyAtLengthCapAccepted() throws {
        // The cap is inclusive — N characters must be accepted, N+1
        // rejected. Pins the boundary.
        let atCap = String(repeating: "x", count: Send.maximumIdentifierLength)
        try Send.validateThreadID(atCap)
    }
}
