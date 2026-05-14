import XCTest
import ArgumentParser
@testable import roar

/// Pinned behaviour for `--badge-count` and `--target-content-id`
/// validators. These are intentionally small surfaces — the actual
/// content-property assignment is a one-liner — but the validators
/// catch the common misuses (negative badge, NUL byte in id) that
/// would otherwise produce silent downstream failures.
final class BadgeAndTargetContentTests: XCTestCase {

    // MARK: - validateBadgeCount

    func testNilAccepted() throws {
        try Send.validateBadgeCount(nil)
    }

    func testZeroAccepted() throws {
        // 0 is the documented "clear the badge" value.
        try Send.validateBadgeCount(0)
    }

    func testPositiveAccepted() throws {
        try Send.validateBadgeCount(42)
    }

    func testNegativeRejected() {
        XCTAssertThrowsError(try Send.validateBadgeCount(-1)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    // MARK: - validateRequestIdentifier with custom flag name

    func testTargetContentIDNilAccepted() throws {
        try Send.validateRequestIdentifier(nil, flagName: "--target-content-id")
    }

    func testTargetContentIDPlainAccepted() throws {
        try Send.validateRequestIdentifier(
            "doc.42", flagName: "--target-content-id")
    }

    func testTargetContentIDEmptyRejected() {
        XCTAssertThrowsError(
            try Send.validateRequestIdentifier(
                "", flagName: "--target-content-id")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testTargetContentIDWhitespaceRejected() {
        XCTAssertThrowsError(
            try Send.validateRequestIdentifier(
                "   ", flagName: "--target-content-id")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testTargetContentIDNullByteRejected() {
        XCTAssertThrowsError(
            try Send.validateRequestIdentifier(
                "doc\0sneaky", flagName: "--target-content-id")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testTargetContentIDNewlineRejected() {
        XCTAssertThrowsError(
            try Send.validateRequestIdentifier(
                "doc\nbad", flagName: "--target-content-id")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testTargetContentIDOverLimitRejected() {
        let longID = String(repeating: "a", count: Send.maximumIdentifierLength + 1)
        XCTAssertThrowsError(
            try Send.validateRequestIdentifier(
                longID, flagName: "--target-content-id")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    /// The default flag name is `--identifier` — keep the existing
    /// `--identifier` tests passing without changes by ensuring the
    /// default-argument call still works.
    func testIdentifierDefaultFlagNameUnchanged() throws {
        try Send.validateRequestIdentifier("ok")
        XCTAssertThrowsError(try Send.validateRequestIdentifier("")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }
}
