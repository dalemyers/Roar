import XCTest
import ArgumentParser
import UserNotifications
@testable import roar

/// Pin the behaviour of `--filter-criteria`:
///
/// * `nil` and a non-empty value both pass; the framework treats
///   `nil` as "no Focus filter hint" and a non-empty value as a
///   Focus-filter match key.
/// * Empty / whitespace-only input is rejected — UN distinguishes
///   `nil` from `""`, and an empty value almost never matches what
///   the user meant.
final class FilterCriteriaTests: XCTestCase {

    func testNilAccepted() throws {
        try Send.validateFilterCriteria(nil)
    }

    func testNonEmptyAccepted() throws {
        try Send.validateFilterCriteria("conversation-42")
    }

    func testWhitespaceAroundContentAccepted() throws {
        // The validator trims for emptiness but does not rewrite the
        // value — the framework receives whatever the user typed.
        try Send.validateFilterCriteria("  conversation-42  ")
    }

    func testEmptyRejected() {
        XCTAssertThrowsError(try Send.validateFilterCriteria("")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testWhitespaceOnlyRejected() {
        XCTAssertThrowsError(try Send.validateFilterCriteria("   ")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
        XCTAssertThrowsError(try Send.validateFilterCriteria("\t\n  ")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    /// NUL truncates at the XPC bridge — visible criteria and
    /// persisted criteria would diverge. Reject up front, matching
    /// the discipline of `--identifier` and `--thread-id`.
    func testNULRejected() {
        XCTAssertThrowsError(try Send.validateFilterCriteria("focus\0work")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testNewlineRejected() {
        XCTAssertThrowsError(try Send.validateFilterCriteria("focus\nwork")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testEmbeddedTabRejected() {
        XCTAssertThrowsError(try Send.validateFilterCriteria("focus\twork")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testESCRejected() {
        XCTAssertThrowsError(try Send.validateFilterCriteria("focus\u{001B}[2J")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    /// Mirrors the identifier cap — UN's XPC surface rejects oversized
    /// strings with an opaque "internal error"; surface a clean
    /// diagnostic up front.
    func testOverLengthRejected() {
        let over = String(repeating: "x", count: Send.maximumIdentifierLength + 1)
        XCTAssertThrowsError(try Send.validateFilterCriteria(over)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testExactlyAtLengthCapAccepted() throws {
        let atCap = String(repeating: "x", count: Send.maximumIdentifierLength)
        try Send.validateFilterCriteria(atCap)
    }
}
