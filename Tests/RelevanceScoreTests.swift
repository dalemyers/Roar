import XCTest
import ArgumentParser
@testable import roar

/// Pinned behaviour for the `--relevance-score` validator. Range
/// [0.0, 1.0], finite, `nil` is a no-op. The framework silently
/// clamps out-of-range values, so the validator is what surfaces
/// user typos.
final class RelevanceScoreTests: XCTestCase {

    func testNilIsAccepted() throws {
        try Send.validateRelevanceScore(nil)
    }

    func testZeroIsAccepted() throws {
        try Send.validateRelevanceScore(0.0)
    }

    func testOneIsAccepted() throws {
        try Send.validateRelevanceScore(1.0)
    }

    func testMidRangeIsAccepted() throws {
        try Send.validateRelevanceScore(0.5)
    }

    func testNegativeIsRejected() {
        XCTAssertThrowsError(try Send.validateRelevanceScore(-0.01)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testAboveOneIsRejected() {
        XCTAssertThrowsError(try Send.validateRelevanceScore(1.01)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    /// A common typo: passing "10" intending 10% rather than 0.1.
    /// Catching it at validation prevents the silent clamp-to-1.0.
    func testTenIsRejected() {
        XCTAssertThrowsError(try Send.validateRelevanceScore(10.0)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testNaNIsRejected() {
        XCTAssertThrowsError(try Send.validateRelevanceScore(.nan)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testInfinityIsRejected() {
        XCTAssertThrowsError(try Send.validateRelevanceScore(.infinity)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
        XCTAssertThrowsError(try Send.validateRelevanceScore(-.infinity)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }
}
