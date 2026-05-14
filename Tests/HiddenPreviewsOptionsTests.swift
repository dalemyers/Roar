import XCTest
import UserNotifications
@testable import roar

/// Pin the behaviour of `--show-title-when-previews-hidden` and
/// `--show-subtitle-when-previews-hidden`: they flow into the
/// UNNotificationCategory's options set as
/// `.hiddenPreviewsShowTitle` / `.hiddenPreviewsShowSubtitle`, and
/// they participate in the SHA-256 category-id hash so two sends with
/// the same actions but different visibility settings get distinct
/// registry entries (the `setNotificationCategories` union-insert
/// would otherwise silently keep the first one).
final class HiddenPreviewsOptionsTests: XCTestCase {

    // MARK: - buildHiddenPreviewsCategoryOptions mapping

    func testNeitherFlagYieldsEmptyOptionSet() {
        let options = Send.buildHiddenPreviewsCategoryOptions(
            showTitle: false, showSubtitle: false)
        XCTAssertTrue(options.isEmpty)
    }

    func testShowTitleFlagMaps() {
        let options = Send.buildHiddenPreviewsCategoryOptions(
            showTitle: true, showSubtitle: false)
        XCTAssertTrue(options.contains(.hiddenPreviewsShowTitle))
        XCTAssertFalse(options.contains(.hiddenPreviewsShowSubtitle))
    }

    func testShowSubtitleFlagMaps() {
        let options = Send.buildHiddenPreviewsCategoryOptions(
            showTitle: false, showSubtitle: true)
        XCTAssertFalse(options.contains(.hiddenPreviewsShowTitle))
        XCTAssertTrue(options.contains(.hiddenPreviewsShowSubtitle))
    }

    func testBothFlagsMap() {
        let options = Send.buildHiddenPreviewsCategoryOptions(
            showTitle: true, showSubtitle: true)
        XCTAssertTrue(options.contains(.hiddenPreviewsShowTitle))
        XCTAssertTrue(options.contains(.hiddenPreviewsShowSubtitle))
    }

    // MARK: - buildCategory propagates extra options

    func testExtraOptionsAppearInCategoryOptions() throws {
        let actions: [Send.ParsedAction] = [
            Send.ParsedAction(id: "ok", title: "OK")
        ]
        let category = try XCTUnwrap(Send.buildCategory(
            for: actions,
            extraCategoryOptions: [
                .hiddenPreviewsShowTitle, .hiddenPreviewsShowSubtitle
            ]))
        // `.customDismissAction` is always set; the new flags ride
        // alongside it.
        XCTAssertTrue(category.options.contains(.customDismissAction))
        XCTAssertTrue(category.options.contains(.hiddenPreviewsShowTitle))
        XCTAssertTrue(category.options.contains(.hiddenPreviewsShowSubtitle))
    }

    func testNoExtraOptionsKeepsCategoryAtCustomDismissOnly() throws {
        let actions: [Send.ParsedAction] = [
            Send.ParsedAction(id: "ok", title: "OK")
        ]
        let category = try XCTUnwrap(Send.buildCategory(for: actions))
        XCTAssertEqual(category.options, [.customDismissAction])
    }

    // MARK: - Empty actions + extra options still register a category

    func testEmptyActionsWithExtraOptionsRegistersCategory() throws {
        // Without metadata and without `dismissableEvenIfEmpty`, the
        // empty-actions case returns nil. With a category-options
        // flag set, the category must exist so the framework has
        // somewhere to read the flag from.
        XCTAssertNil(Send.buildCategory(for: []))
        let category = try XCTUnwrap(Send.buildCategory(
            for: [],
            extraCategoryOptions: [.hiddenPreviewsShowTitle]))
        XCTAssertTrue(category.options.contains(.hiddenPreviewsShowTitle))
        // The stable dismissable-empty id is reserved for the no-metadata
        // case; once a flag is set the registry needs a unique slot.
        XCTAssertNotEqual(category.identifier, Send.dismissableEmptyCategoryID)
    }

    // MARK: - Identifier stability under extra options

    func testSameActionsDifferentExtraOptionsGetDifferentIds() {
        let actions: [Send.ParsedAction] = [
            Send.ParsedAction(id: "ok", title: "OK")
        ]
        let none = Send.categoryIdentifier(for: actions)
        let title = Send.categoryIdentifier(
            for: actions,
            extraCategoryOptions: [.hiddenPreviewsShowTitle])
        let both = Send.categoryIdentifier(
            for: actions,
            extraCategoryOptions: [
                .hiddenPreviewsShowTitle, .hiddenPreviewsShowSubtitle
            ])
        XCTAssertNotEqual(none, title)
        XCTAssertNotEqual(none, both)
        XCTAssertNotEqual(title, both)
    }

    func testEmptyExtraOptionsMatchesLegacyIdentifier() {
        // The doc comment promises: when no metadata is set,
        // categoryIdentifier preserves byte-compat with older roar
        // binaries that hashed only the actions block. An empty
        // `extraCategoryOptions` must not break that.
        let actions: [Send.ParsedAction] = [
            Send.ParsedAction(id: "ok", title: "OK")
        ]
        let plain = Send.categoryIdentifier(for: actions)
        let explicitEmpty = Send.categoryIdentifier(
            for: actions,
            hiddenPreviewsBodyPlaceholder: nil,
            categorySummaryFormat: nil,
            extraCategoryOptions: [])
        XCTAssertEqual(plain, explicitEmpty)
    }

    func testExtraOptionsOrthogonalToPlaceholder() {
        // The two metadata blocks (placeholder/summary vs. options)
        // hang off separate group separators. Verify each axis can
        // vary independently and produces a unique id.
        let actions: [Send.ParsedAction] = [
            Send.ParsedAction(id: "ok", title: "OK")
        ]
        let placeholderOnly = Send.categoryIdentifier(
            for: actions,
            hiddenPreviewsBodyPlaceholder: "Auth code",
            categorySummaryFormat: nil,
            extraCategoryOptions: [])
        let placeholderAndShow = Send.categoryIdentifier(
            for: actions,
            hiddenPreviewsBodyPlaceholder: "Auth code",
            categorySummaryFormat: nil,
            extraCategoryOptions: [.hiddenPreviewsShowTitle])
        XCTAssertNotEqual(placeholderOnly, placeholderAndShow)
    }
}
