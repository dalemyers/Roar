import XCTest
import UserNotifications
@testable import roar

/// Pin the behaviour of `--hide-previews-body-placeholder` and
/// `--summary-format`: they flow into the UNNotificationCategory's
/// `hiddenPreviewsBodyPlaceholder` and `categorySummaryFormat`, and
/// they participate in the SHA-256 category-id hash so two sends with
/// the same actions but different metadata get distinct registry
/// entries.
final class CategoryPreviewSummaryTests: XCTestCase {

    // MARK: - Identifier stability under metadata variation

    func testSameActionsDifferentPlaceholderGetDifferentIds() {
        // Two notifications with identical action sets but different
        // hidden-previews placeholders must produce different
        // category identifiers — otherwise `setNotificationCategories`
        // union-insert would silently keep the first one and drop the
        // second, defeating the per-send override.
        let actions: [Send.ParsedAction] = [
            Send.ParsedAction(id: "ok", title: "OK")
        ]
        let a = Send.categoryIdentifier(
            for: actions,
            hiddenPreviewsBodyPlaceholder: "Auth code",
            categorySummaryFormat: nil)
        let b = Send.categoryIdentifier(
            for: actions,
            hiddenPreviewsBodyPlaceholder: "Private message",
            categorySummaryFormat: nil)
        XCTAssertNotEqual(a, b)
    }

    func testSameActionsDifferentSummaryGetDifferentIds() {
        let actions: [Send.ParsedAction] = [
            Send.ParsedAction(id: "ok", title: "OK")
        ]
        let a = Send.categoryIdentifier(
            for: actions,
            hiddenPreviewsBodyPlaceholder: nil,
            categorySummaryFormat: "%u more messages")
        let b = Send.categoryIdentifier(
            for: actions,
            hiddenPreviewsBodyPlaceholder: nil,
            categorySummaryFormat: "%u additional alerts")
        XCTAssertNotEqual(a, b)
    }

    func testNoMetadataMatchesLegacyIdentifier() {
        // Existing categoryIdentifier(for:) callers pass no metadata.
        // The new defaulted overload must produce the same digest so
        // categories registered by older roar binaries (still alive in
        // usernoted's per-bundle registry between sends) stay
        // identified by the same hash.
        let actions: [Send.ParsedAction] = [
            Send.ParsedAction(id: "ok", title: "OK")
        ]
        let plain = Send.categoryIdentifier(for: actions)
        let plainExplicit = Send.categoryIdentifier(
            for: actions,
            hiddenPreviewsBodyPlaceholder: nil,
            categorySummaryFormat: nil)
        XCTAssertEqual(plain, plainExplicit)
    }

    // MARK: - buildCategory threads metadata into UN

    func testHiddenPreviewsBodyPlaceholderFlowsToCategory() throws {
        let actions: [Send.ParsedAction] = [
            Send.ParsedAction(id: "ok", title: "OK")
        ]
        let category = try XCTUnwrap(Send.buildCategory(
            for: actions,
            hiddenPreviewsBodyPlaceholder: "Auth code",
            categorySummaryFormat: nil))
        XCTAssertEqual(category.hiddenPreviewsBodyPlaceholder, "Auth code")
    }

    func testSummaryFormatFlowsToCategory() throws {
        let actions: [Send.ParsedAction] = [
            Send.ParsedAction(id: "ok", title: "OK")
        ]
        let category = try XCTUnwrap(Send.buildCategory(
            for: actions,
            hiddenPreviewsBodyPlaceholder: nil,
            categorySummaryFormat: "%u more"))
        XCTAssertEqual(category.categorySummaryFormat, "%u more")
    }

    // MARK: - Empty actions + metadata still build a category

    func testEmptyActionsWithPlaceholderStillRegistersCategory() throws {
        // Without metadata, the empty-actions case returns nil
        // (no reason to register). With a placeholder set, the
        // category must exist so the framework has somewhere to read
        // the preview text from.
        XCTAssertNil(Send.buildCategory(
            for: [],
            hiddenPreviewsBodyPlaceholder: nil,
            categorySummaryFormat: nil))
        let category = try XCTUnwrap(Send.buildCategory(
            for: [],
            hiddenPreviewsBodyPlaceholder: "Auth code",
            categorySummaryFormat: nil))
        XCTAssertEqual(category.hiddenPreviewsBodyPlaceholder, "Auth code")
        // Empty-actions + metadata still hashes the identifier — the
        // stable `dismissableEmptyCategoryID` would let two sends
        // with different placeholders collide on the same registry
        // slot.
        XCTAssertNotEqual(category.identifier, Send.dismissableEmptyCategoryID)
    }

    func testEmptyActionsDismissableNoMetadataReusesStableID() throws {
        // The `--wait` no-actions path — no metadata, just the
        // .customDismissAction signal — keeps reusing the single
        // stable identifier so the registry doesn't grow per-send.
        let category = try XCTUnwrap(Send.buildCategory(
            for: [],
            dismissableEvenIfEmpty: true,
            hiddenPreviewsBodyPlaceholder: nil,
            categorySummaryFormat: nil))
        XCTAssertEqual(category.identifier, Send.dismissableEmptyCategoryID)
    }
}
