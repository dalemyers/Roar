import XCTest
import ArgumentParser
@testable import roar

/// Pinned behaviour for the `--target-content-id` validator (it
/// reuses `validateRequestIdentifier` with a custom flag name). The
/// validator catches the common NUL / control-char / length misuses
/// that would otherwise produce silent downstream failures at the
/// XPC bridge.
final class TargetContentTests: XCTestCase {

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
