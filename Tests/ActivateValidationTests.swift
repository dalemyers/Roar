import XCTest
import ArgumentParser
@testable import roar

/// Pin the empty/whitespace rejection on `--activate-bundle-id`. Empty strings
/// would otherwise land in `userInfo["roar.activate.bundleID"]`, and the click
/// handler would resolve `urlForApplication(withBundleIdentifier: "")`
/// to nil and report "Activate target not found." Surface the bad
/// input at send time instead.
final class ActivateValidationTests: XCTestCase {

    func testNilActivateIsAccepted() throws {
        try Send.validateActivateBundleID(nil)
    }

    func testNormalBundleIdIsAccepted() throws {
        try Send.validateActivateBundleID("com.apple.Safari")
    }

    func testEmptyActivateThrows() {
        XCTAssertThrowsError(try Send.validateActivateBundleID("")) { error in
            XCTAssertTrue(error is ValidationError,
                          "Expected ValidationError, got \(type(of: error))")
        }
    }

    func testWhitespaceOnlyActivateThrows() {
        // Whitespace-only is also unambiguously malformed — a real
        // bundle id is a dotted reverse-DNS identifier with no
        // whitespace.
        XCTAssertThrowsError(try Send.validateActivateBundleID("   ")) { error in
            XCTAssertTrue(error is ValidationError)
        }
        XCTAssertThrowsError(try Send.validateActivateBundleID("\t\n")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testRejectsNULInBundleID() {
        // NUL truncates at the XPC C-string bridge — a value like
        // `com.apple\0evil` would round-trip through userInfo as
        // `com.apple`, silently activating a different bundle than the
        // user typed. Mirror the discipline applied to other
        // identifier-shaped flags.
        XCTAssertThrowsError(
            try Send.validateActivateBundleID("com.apple\0evil")
        ) { error in
            XCTAssertTrue(error is ValidationError,
                          "got \(type(of: error))")
        }
    }
}
