import XCTest
import ArgumentParser
import UserNotifications
@testable import roar

/// Pinned behaviour for `--text-action` parsing, the cross-flag
/// uniqueness check, and the side-flag validation (placeholder /
/// button-title require text-action).
final class TextActionTests: XCTestCase {

    // MARK: - parseTextActions: acceptance

    func testEmptyArrayProducesEmptyResult() throws {
        let parsed = try Send.parseTextActions(
            [], placeholder: "", buttonTitle: "")
        XCTAssertTrue(parsed.isEmpty)
    }

    func testSingleTextActionParsed() throws {
        let parsed = try Send.parseTextActions(
            ["reply:Reply"], placeholder: "Type something", buttonTitle: "Go")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, "reply")
        XCTAssertEqual(parsed[0].title, "Reply")
        if case .textInput(let placeholder, let buttonTitle) = parsed[0].kind {
            XCTAssertEqual(placeholder, "Type something")
            XCTAssertEqual(buttonTitle, "Go")
        } else {
            XCTFail("Expected .textInput kind")
        }
    }

    func testOptionsThreadIntoTextAction() throws {
        let parsed = try Send.parseTextActions(
            ["reply:Reply::destructive"], placeholder: "", buttonTitle: "")
        XCTAssertTrue(parsed[0].options.contains(.destructive))
    }

    // MARK: - parseTextActions: rejection

    func testMultipleTextActionsRejected() {
        XCTAssertThrowsError(
            try Send.parseTextActions(
                ["a:A", "b:B"], placeholder: "", buttonTitle: "")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testReservedIDRejected() {
        XCTAssertThrowsError(
            try Send.parseTextActions(
                ["default:Default"], placeholder: "", buttonTitle: "")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - validateActionIDUniqueness

    func testCombinedCountWithinLimitAccepted() throws {
        let buttons = try Send.parseActions(["a:A", "b:B", "c:C"])
        let texts = try Send.parseTextActions(
            ["d:D"], placeholder: "", buttonTitle: "")
        // 3 buttons + 1 text-input = 4 = maxActionCount
        try Send.validateActionIDUniqueness(buttons: buttons, textInputs: texts)
    }

    func testCombinedCountOverLimitRejected() throws {
        let buttons = try Send.parseActions(["a:A", "b:B", "c:C", "d:D"])
        let texts = try Send.parseTextActions(
            ["e:E"], placeholder: "", buttonTitle: "")
        XCTAssertThrowsError(
            try Send.validateActionIDUniqueness(
                buttons: buttons, textInputs: texts)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testCollidingIDsRejected() throws {
        let buttons = try Send.parseActions(["reply:Quick reply"])
        let texts = try Send.parseTextActions(
            ["reply:Long reply"], placeholder: "", buttonTitle: "")
        XCTAssertThrowsError(
            try Send.validateActionIDUniqueness(
                buttons: buttons, textInputs: texts)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - validateTextSideOptions

    func testNoTextActionPlaceholderRejected() {
        XCTAssertThrowsError(
            try Send.validateTextSideOptions(
                textActions: [],
                textPlaceholder: "Type here",
                textButtonTitle: nil)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testNoTextActionButtonTitleRejected() {
        XCTAssertThrowsError(
            try Send.validateTextSideOptions(
                textActions: [],
                textPlaceholder: nil,
                textButtonTitle: "Send")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testNoTextActionNoSideOptionsIsFine() throws {
        try Send.validateTextSideOptions(
            textActions: [],
            textPlaceholder: nil,
            textButtonTitle: nil)
    }

    func testTextActionWithSideOptionsIsFine() throws {
        try Send.validateTextSideOptions(
            textActions: ["reply:Reply"],
            textPlaceholder: "Type",
            textButtonTitle: "Send")
    }
}
