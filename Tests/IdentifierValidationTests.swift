import XCTest
import ArgumentParser
@testable import roar

/// Pinned behaviour for `--identifier` validation. UN uses this
/// string as the key for replace/dismiss/list, so corruption of it
/// propagates to downstream commands; NUL is particularly bad because
/// the C-string bridge truncates at the first NUL.
final class IdentifierValidationTests: XCTestCase {

    func testNilAccepted() throws {
        try Send.validateRequestIdentifier(nil)
    }

    func testNormalIdAccepted() throws {
        try Send.validateRequestIdentifier("build-results")
        try Send.validateRequestIdentifier("io.myers.build.123")
        try Send.validateRequestIdentifier("UUID-form-9F8E7D6C-1234-5678-90AB-CDEF01234567")
    }

    func testEmptyRejected() {
        XCTAssertThrowsError(try Send.validateRequestIdentifier("")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testWhitespaceOnlyRejected() {
        XCTAssertThrowsError(try Send.validateRequestIdentifier("   ")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testNullByteRejected() {
        XCTAssertThrowsError(
            try Send.validateRequestIdentifier("build\0result")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testNewlineRejected() {
        XCTAssertThrowsError(
            try Send.validateRequestIdentifier("line1\nline2")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testTabRejected() {
        XCTAssertThrowsError(
            try Send.validateRequestIdentifier("a\tb")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testOversizeRejected() {
        let oversized = String(repeating: "a", count: Send.maximumIdentifierLength + 1)
        XCTAssertThrowsError(
            try Send.validateRequestIdentifier(oversized)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testExactlyAtLimitAccepted() throws {
        let atLimit = String(repeating: "a", count: Send.maximumIdentifierLength)
        try Send.validateRequestIdentifier(atLimit)
    }
}
