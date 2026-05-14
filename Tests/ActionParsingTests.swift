import XCTest
import ArgumentParser
import UserNotifications
@testable import roar

/// Pinned behaviour for `--action` parsing, action/wait compatibility,
/// stable category-id construction, and category building.
final class ActionParsingTests: XCTestCase {

    // MARK: - parseActions: acceptance

    func testEmptyArrayProducesEmptyResult() throws {
        let parsed = try Send.parseActions([])
        XCTAssertTrue(parsed.isEmpty)
    }

    func testSingleActionParsed() throws {
        let parsed = try Send.parseActions(["approve:Approve"])
        XCTAssertEqual(parsed, [
            Send.ParsedAction(id: "approve", title: "Approve")
        ])
    }

    func testMultipleActionsParsedInOrder() throws {
        let parsed = try Send.parseActions(["a:A", "b:B", "c:C"])
        XCTAssertEqual(parsed.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(parsed.map(\.title), ["A", "B", "C"])
    }

    func testTitleMayContainColons() throws {
        // Split is on FIRST `:` only, so titles can carry punctuation
        // including more colons.
        let parsed = try Send.parseActions(["go:Open: details"])
        XCTAssertEqual(parsed, [
            Send.ParsedAction(id: "go", title: "Open: details")
        ])
    }

    func testIdsWithUnderscoresAndDashesAccepted() throws {
        // No restriction beyond "no whitespace / control chars" — the
        // parser shouldn't get prescriptive about identifier shape.
        let parsed = try Send.parseActions(["snooze_v2:Snooze", "ack-now:Ack"])
        XCTAssertEqual(parsed.map(\.id), ["snooze_v2", "ack-now"])
    }

    // MARK: - parseActions: rejection

    func testMissingColonRejected() {
        XCTAssertThrowsError(try Send.parseActions(["approveOnly"])) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testEmptyIdRejected() {
        XCTAssertThrowsError(try Send.parseActions([":Approve"])) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testEmptyTitleRejected() {
        XCTAssertThrowsError(try Send.parseActions(["approve:"])) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testWhitespaceInIdRejected() {
        XCTAssertThrowsError(try Send.parseActions(["my id:Title"])) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testNewlineInIdRejected() {
        XCTAssertThrowsError(try Send.parseActions(["a\nb:Title"])) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testNullByteInIdRejected() {
        XCTAssertThrowsError(try Send.parseActions(["a\0b:Title"])) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testReservedDefaultIdRejected() {
        XCTAssertThrowsError(try Send.parseActions(["default:Default"])) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testReservedDismissIdRejected() {
        XCTAssertThrowsError(try Send.parseActions(["dismiss:Dismiss"])) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testDuplicateIdRejected() {
        XCTAssertThrowsError(
            try Send.parseActions(["approve:Yes", "approve:Also yes"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testTooManyActionsRejected() {
        XCTAssertThrowsError(
            try Send.parseActions((1...5).map { "id\($0):Title \($0)" })
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testExactlyMaxActionsAccepted() throws {
        let parsed = try Send.parseActions(
            (1...Send.maxActionCount).map { "id\($0):Title \($0)" })
        XCTAssertEqual(parsed.count, Send.maxActionCount)
    }

    // MARK: - validateActionWaitCompatibility

    func testActionsRequireWait() {
        XCTAssertThrowsError(
            try Send.validateActionWaitCompatibility(
                actionsCount: 1, wait: false, exec: nil,
                openURL: nil, activateBundleID: nil)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testNoActionsNoWaitIsFine() throws {
        try Send.validateActionWaitCompatibility(
            actionsCount: 0, wait: false, exec: nil,
            openURL: nil, activateBundleID: nil)
    }

    func testActionsWithWaitIsFine() throws {
        try Send.validateActionWaitCompatibility(
            actionsCount: 2, wait: true, exec: nil,
            openURL: nil, activateBundleID: nil)
    }

    func testWaitConflictsWithExec() {
        XCTAssertThrowsError(
            try Send.validateActionWaitCompatibility(
                actionsCount: 0, wait: true, exec: "echo hi",
                openURL: nil, activateBundleID: nil)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testWaitConflictsWithOpenURL() {
        XCTAssertThrowsError(
            try Send.validateActionWaitCompatibility(
                actionsCount: 0, wait: true, exec: nil,
                openURL: "https://example.com", activateBundleID: nil)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testWaitConflictsWithActivate() {
        XCTAssertThrowsError(
            try Send.validateActionWaitCompatibility(
                actionsCount: 0, wait: true, exec: nil,
                openURL: nil, activateBundleID: "com.apple.Safari")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - categoryIdentifier

    func testCategoryIdHasRoarPrefix() {
        let id = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "a", title: "A")
        ])
        XCTAssertTrue(id.hasPrefix("roar.dyn."))
    }

    func testCategoryIdStableForSameActions() {
        let id1 = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "a", title: "A"),
            Send.ParsedAction(id: "b", title: "B"),
        ])
        let id2 = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "a", title: "A"),
            Send.ParsedAction(id: "b", title: "B"),
        ])
        XCTAssertEqual(id1, id2)
    }

    func testCategoryIdInsensitiveToInputOrder() {
        // Two invocations with the same buttons in different order
        // should share a category, otherwise we'd grow the registered
        // set on every reordering.
        let id1 = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "a", title: "A"),
            Send.ParsedAction(id: "b", title: "B"),
        ])
        let id2 = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "b", title: "B"),
            Send.ParsedAction(id: "a", title: "A"),
        ])
        XCTAssertEqual(id1, id2)
    }

    func testCategoryIdDiffersOnTitleChange() {
        // Changing a title should produce a new category — otherwise a
        // user editing their notification's labels would see stale
        // buttons.
        let id1 = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "a", title: "A")
        ])
        let id2 = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "a", title: "A2")
        ])
        XCTAssertNotEqual(id1, id2)
    }

    func testCategoryIdDiffersOnIdChange() {
        let id1 = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "a", title: "A")
        ])
        let id2 = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "b", title: "A")
        ])
        XCTAssertNotEqual(id1, id2)
    }

    /// Pin the SHA-256 prefix for a known canonical input. Same-process
    /// stability (`testCategoryIdStableForSameActions`) passes
    /// vacuously under `Hasher` because the random seed is constant
    /// within one process — only a known-vector test catches a
    /// regression to the canonical-form shape that broke cross-process
    /// determinism.
    ///
    /// Reference computation (Python):
    ///   `hashlib.sha256(b"a\x1fA\x1f0\x1fB\x1f\x1f").hexdigest()[:16]`
    /// where the canonical-form fields are joined by U+001F: id,
    /// title, options.rawValue, kind-tag (B = button), placeholder,
    /// buttonTitle. The trailing two empty fields produce two
    /// adjacent U+001F separators. First 8 bytes hex → `108ea25a7759b1cc`.
    func testCategoryIdMatchesKnownDigest() {
        let id = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "a", title: "A")
        ])
        XCTAssertEqual(id, "roar.dyn.108ea25a7759b1cc")
    }

    /// Pinned digest also changes when action options change — make
    /// sure `options.rawValue` is woven into the canonical form, not
    /// stripped.
    func testCategoryIdDiffersOnOptionsChange() {
        let id1 = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "a", title: "A", options: [])
        ])
        let id2 = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "a", title: "A", options: [.destructive])
        ])
        XCTAssertNotEqual(id1, id2)
    }

    /// And when kind changes — a text-input version of the same id /
    /// title pair is a different category, otherwise reusing a stale
    /// registered category would render the wrong UI affordance.
    func testCategoryIdDiffersOnKindChange() {
        let id1 = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "a", title: "A", kind: .button)
        ])
        let id2 = Send.categoryIdentifier(for: [
            Send.ParsedAction(id: "a", title: "A",
                              kind: .textInput(placeholder: "", buttonTitle: ""))
        ])
        XCTAssertNotEqual(id1, id2)
    }

    // MARK: - buildCategory

    func testBuildCategoryReturnsNilForEmpty() {
        XCTAssertNil(Send.buildCategory(for: []))
    }

    func testBuildCategoryWiresIdsAndTitles() throws {
        let actions = [
            Send.ParsedAction(id: "a", title: "Alpha"),
            Send.ParsedAction(id: "b", title: "Bravo"),
        ]
        let category = try XCTUnwrap(Send.buildCategory(for: actions))
        XCTAssertEqual(category.identifier,
                       Send.categoryIdentifier(for: actions))
        XCTAssertEqual(category.actions.map(\.identifier), ["a", "b"])
        XCTAssertEqual(category.actions.map(\.title), ["Alpha", "Bravo"])
    }

    func testBuiltActionsAreNonForeground() throws {
        // The default click on an action shouldn't surface Roar's hidden
        // bundle — the empty options array (when no flags are passed)
        // enforces that.
        let actions = [Send.ParsedAction(id: "a", title: "A")]
        let category = try XCTUnwrap(Send.buildCategory(for: actions))
        XCTAssertFalse(category.actions[0].options.contains(.foreground))
    }

    /// `.customDismissAction` on the category is what makes
    /// swipe-dismiss fire `didReceive` with
    /// `UNNotificationDismissActionIdentifier`. Without it, dismissal
    /// is silent and `--wait` hangs until its timeout — a regression
    /// would be invisible at build time but obvious to users, so the
    /// test pins the bit explicitly.
    func testCategoryHasCustomDismissActionOption() throws {
        let actions = [Send.ParsedAction(id: "a", title: "A")]
        let category = try XCTUnwrap(Send.buildCategory(for: actions))
        XCTAssertTrue(category.options.contains(.customDismissAction))
    }

    /// `--wait` with no `--action`/`--text-action` still needs swipe-
    /// dismiss observability — without a category at all, the
    /// framework can't attach `.customDismissAction` and `--wait`
    /// hangs through every dismiss. `dismissableEvenIfEmpty: true`
    /// produces a stable empty category that papers over the gap.
    func testEmptyActionsWithDismissableEvenIfEmptyProducesCategory() throws {
        let category = try XCTUnwrap(
            Send.buildCategory(for: [], dismissableEvenIfEmpty: true))
        XCTAssertEqual(category.identifier, Send.dismissableEmptyCategoryID)
        XCTAssertTrue(category.actions.isEmpty)
        XCTAssertTrue(category.options.contains(.customDismissAction))
    }

    /// The dismissable-empty category's id is a stable constant —
    /// reusing the same id across invocations keeps the
    /// `setNotificationCategories` registry from growing on every
    /// `roar send --wait` without buttons.
    func testDismissableEmptyCategoryIDIsStable() {
        XCTAssertEqual(Send.dismissableEmptyCategoryID, "roar.dyn.dismissable")
    }

    /// Default behaviour preserved: empty actions, no `--wait`, no
    /// category. Avoids polluting the registered set for fire-and-
    /// forget notifications that don't need dismiss observability.
    func testEmptyActionsDefaultStillReturnsNil() {
        XCTAssertNil(Send.buildCategory(for: []))
    }

    /// Options flow through from `ParsedAction.options` to the built
    /// `UNNotificationAction.options` set verbatim — a regression
    /// where one bit got masked off would silently downgrade a
    /// destructive button to plain.
    func testBuiltActionsPropagateOptions() throws {
        let actions = [
            Send.ParsedAction(id: "delete", title: "Delete",
                              options: [.destructive]),
            Send.ParsedAction(id: "auth", title: "Auth",
                              options: [.authenticationRequired]),
        ]
        let category = try XCTUnwrap(Send.buildCategory(for: actions))
        XCTAssertTrue(category.actions[0].options.contains(.destructive))
        XCTAssertTrue(category.actions[1].options.contains(.authenticationRequired))
    }

    /// Text-input actions must come out as `UNTextInputNotificationAction`
    /// instances, not plain `UNNotificationAction`s. The framework
    /// renders a reply field for the former and a tap-only button for
    /// the latter, so a regression would silently drop the input field.
    func testTextInputActionsAreCorrectType() throws {
        let actions = [
            Send.ParsedAction(
                id: "reply", title: "Reply",
                kind: .textInput(placeholder: "Type", buttonTitle: "Send"))
        ]
        let category = try XCTUnwrap(Send.buildCategory(for: actions))
        let textAction = try XCTUnwrap(
            category.actions[0] as? UNTextInputNotificationAction)
        XCTAssertEqual(textAction.textInputPlaceholder, "Type")
        XCTAssertEqual(textAction.textInputButtonTitle, "Send")
    }
}
