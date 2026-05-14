import XCTest
import UserNotifications
@testable import roar

/// Pin the two pure-function helpers behind `roar clear --categories`.
/// The async wrapper that hits `UNUserNotificationCenter` is just a
/// glue layer over these.
final class CategoryPruneTests: XCTestCase {

    // MARK: - referencedCategoryIDs

    func testEmptyInputsProduceEmptySet() {
        XCTAssertTrue(
            Clear.referencedCategoryIDs(delivered: [], pending: []).isEmpty)
    }

    func testReferencedUnionsBothBuckets() {
        let set = Clear.referencedCategoryIDs(
            delivered: ["roar.dyn.aaa", "roar.dyn.bbb"],
            pending: ["roar.dyn.bbb", "roar.dyn.ccc"]
        )
        XCTAssertEqual(set, ["roar.dyn.aaa", "roar.dyn.bbb", "roar.dyn.ccc"])
    }

    func testEmptyIdentifierIsNotReferenced() {
        // A notification without `categoryIdentifier` reports the
        // empty string in UN — that doesn't keep any registry entry
        // alive, so the prune helper must skip it.
        let set = Clear.referencedCategoryIDs(
            delivered: ["", "roar.dyn.aaa"], pending: [""])
        XCTAssertEqual(set, ["roar.dyn.aaa"])
    }

    // MARK: - filterPrunedCategories

    func testNonDynamicCategoriesAlwaysKept() {
        // A hand-rolled category (any identifier not starting with
        // `roar.dyn.`) must survive the prune regardless of whether
        // it's referenced — the prune scope is intentionally narrow
        // to keep sibling app / future-feature registrations safe.
        let kept = UNNotificationCategory(
            identifier: "user.custom",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let result = Clear.filterPrunedCategories(
            categories: [kept], referenced: [])
        XCTAssertEqual(result, [kept])
    }

    func testUnreferencedDynamicCategoryIsRemoved() {
        let stale = UNNotificationCategory(
            identifier: "roar.dyn.deadbeef",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let result = Clear.filterPrunedCategories(
            categories: [stale], referenced: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testReferencedDynamicCategoryIsKept() {
        let live = UNNotificationCategory(
            identifier: "roar.dyn.cafebabe",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let result = Clear.filterPrunedCategories(
            categories: [live], referenced: ["roar.dyn.cafebabe"])
        XCTAssertEqual(result, [live])
    }

    func testMixedSetPartitionsCorrectly() {
        let userCategory = UNNotificationCategory(
            identifier: "user.custom",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let liveDynamic = UNNotificationCategory(
            identifier: "roar.dyn.live",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let staleDynamic = UNNotificationCategory(
            identifier: "roar.dyn.stale",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let result = Clear.filterPrunedCategories(
            categories: [userCategory, liveDynamic, staleDynamic],
            referenced: ["roar.dyn.live"]
        )
        XCTAssertEqual(result, [userCategory, liveDynamic])
    }

    func testPrefixMatchIsLiteral() {
        // The prefix check is a literal `hasPrefix("roar.dyn.")` —
        // anything that just happens to start with the substring
        // somewhere else in the id is NOT a roar-managed category
        // and must be kept regardless of reference state. The most
        // realistic shape of this is a user-chosen id like
        // `myapp.roar.dyn.thing`.
        let lookalike = UNNotificationCategory(
            identifier: "myapp.roar.dyn.thing",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let result = Clear.filterPrunedCategories(
            categories: [lookalike], referenced: [])
        XCTAssertEqual(result, [lookalike])
    }
}
