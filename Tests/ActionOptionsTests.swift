import XCTest
import ArgumentParser
import UserNotifications
@testable import roar

/// Pinned behaviour for the `--action` / `--text-action` `::flag,flag`
/// suffix. Covers the option parser itself plus the integration with
/// the full `parseActions` / `parseTextActions` pipeline.
final class ActionOptionsTests: XCTestCase {

    // MARK: - parseActionOptions

    func testEmptyListRejected() {
        // An empty string would imply "options were intended but none
        // listed" — surface the mistake. Note that a value without
        // `::` at all goes through the no-options branch and never
        // reaches this parser.
        XCTAssertThrowsError(
            try Send.parseActionOptions("", raw: "id:Title::")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testSingleKnownOptionParsed() throws {
        let options = try Send.parseActionOptions(
            "destructive", raw: "delete:Delete::destructive")
        XCTAssertTrue(options.contains(.destructive))
    }

    func testMultipleOptionsParsed() throws {
        let options = try Send.parseActionOptions(
            "destructive,auth-required",
            raw: "confirm:Confirm::destructive,auth-required")
        XCTAssertTrue(options.contains(.destructive))
        XCTAssertTrue(options.contains(.authenticationRequired))
    }

    func testUnknownOptionRejected() {
        XCTAssertThrowsError(
            try Send.parseActionOptions(
                "foreground", raw: "a:A::foreground")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testStrayCommaRejected() {
        XCTAssertThrowsError(
            try Send.parseActionOptions(
                "destructive,", raw: "a:A::destructive,")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testLeadingCommaRejected() {
        XCTAssertThrowsError(
            try Send.parseActionOptions(
                ",destructive", raw: "a:A::,destructive")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testDuplicateOptionRejected() {
        XCTAssertThrowsError(
            try Send.parseActionOptions(
                "destructive,destructive",
                raw: "a:A::destructive,destructive")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - parseActions integration

    func testActionParsedWithDestructiveFlag() throws {
        let parsed = try Send.parseActions(["delete:Delete::destructive"])
        XCTAssertEqual(parsed[0].id, "delete")
        XCTAssertEqual(parsed[0].title, "Delete")
        XCTAssertTrue(parsed[0].options.contains(.destructive))
    }

    func testActionParsedWithBothFlags() throws {
        let parsed = try Send.parseActions(
            ["delete:Delete::destructive,auth-required"])
        XCTAssertTrue(parsed[0].options.contains(.destructive))
        XCTAssertTrue(parsed[0].options.contains(.authenticationRequired))
    }

    /// Titles with a single `:` continue to work — the suffix detector
    /// looks for the LAST `::`, not any `:`. A regression to greedy
    /// splitting would re-break the existing
    /// `testTitleMayContainColons` shape.
    func testTitleWithSingleColonStillParses() throws {
        let parsed = try Send.parseActions(["go:Open: details"])
        XCTAssertEqual(parsed[0].title, "Open: details")
        XCTAssertTrue(parsed[0].options.isEmpty)
    }

    /// Titles with a single colon plus an options suffix.
    func testTitleWithColonAndOptionsParsed() throws {
        let parsed = try Send.parseActions(
            ["go:Open: details::destructive"])
        XCTAssertEqual(parsed[0].title, "Open: details")
        XCTAssertTrue(parsed[0].options.contains(.destructive))
    }

    func testBadOptionInSuffixRejected() {
        XCTAssertThrowsError(
            try Send.parseActions(["delete:Delete::bogus"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    /// Whitespace around the comma-separated flag entries is tolerated
    /// — `--action 'a:A::destructive, auth-required'` (space after
    /// comma, the natural shape to type) parses as both flags. Without
    /// the trim, the rejected `' auth-required'` would mislead.
    func testCommaSeparatedFlagsTolerateWhitespace() throws {
        let options = try Send.parseActionOptions(
            "destructive, auth-required",
            raw: "a:A::destructive, auth-required")
        XCTAssertTrue(options.contains(.destructive))
        XCTAssertTrue(options.contains(.authenticationRequired))
    }

    /// More than one `::` is ambiguous — `id:Title::dest::auth-required`
    /// would otherwise silently fold `Title::dest` into the title and
    /// only treat `auth-required` as a flag. Reject up-front so the
    /// user notices.
    func testMultipleDoubleColonRejected() {
        XCTAssertThrowsError(
            try Send.parseActions(
                ["a:Title::destructive::auth-required"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }
}
