import XCTest
import UserNotifications
@testable import roar

/// Pin the double-snapshot prune-merge logic that
/// `Clear.pruneUnreferencedDynamicCategories` uses to avoid
/// clobbering categories registered by a concurrent `roar send`.
///
/// The orchestration takes two snapshots (`(categories, references)`)
/// either side of the async gap before the
/// `setNotificationCategories` write. `mergePrunedCategories`
/// reduces those snapshots to the final category set. The rules
/// — additions are preserved, references from either snapshot
/// count — are exercised here without touching UN.
final class CategoryPruneMergeTests: XCTestCase {

    /// Helper for building categories in one line per identifier.
    /// `UNNotificationCategory.hash` keys on the identifier alone, so
    /// two categories built with the same identifier compare equal
    /// regardless of action list — matches how the orchestrator's
    /// `subtracting`-based addition detection behaves.
    private func category(_ id: String) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: id,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
    }

    /// No-op case: both snapshots identical, no references → all
    /// `roar.dyn.*` entries dropped, non-dynamic kept.
    func testIdenticalSnapshotsBehaveLikeSingleSnapshot() {
        let user = category("user.custom")
        let dynStale = category("roar.dyn.aaa")
        let snapshot: Set<UNNotificationCategory> = [user, dynStale]
        let result = Clear.mergePrunedCategories(
            categories1: snapshot,
            categories2: snapshot,
            referenced1: [],
            referenced2: []
        )
        XCTAssertEqual(result, [user])
    }

    /// The headline case: a concurrent `roar send` registered a new
    /// `roar.dyn.cafebabe` category between snapshot 1 and snapshot 2,
    /// and its pending notification is in snapshot 2's pending list.
    /// The merge must preserve the addition.
    func testConcurrentSendAdditionIsPreserved() {
        let user = category("user.custom")
        let dynStale = category("roar.dyn.stale")
        let dynNew = category("roar.dyn.cafebabe")
        let categories1: Set<UNNotificationCategory> = [user, dynStale]
        let categories2: Set<UNNotificationCategory> = [user, dynStale, dynNew]
        // Snapshot 2's pending bucket sees the new notification —
        // its categoryIdentifier keeps the addition alive.
        let result = Clear.mergePrunedCategories(
            categories1: categories1,
            categories2: categories2,
            referenced1: [],
            referenced2: ["roar.dyn.cafebabe"]
        )
        // `user` and the addition survive; the genuinely stale one is gone.
        XCTAssertEqual(result, [user, dynNew])
    }

    /// An addition that's `roar.dyn.*` BUT unreferenced in either
    /// snapshot is still pruned. The "preserve concurrent sends"
    /// rule isn't "preserve every addition unconditionally" —
    /// stale entries that happen to appear during the gap still
    /// get the prune rule applied. Matches the design intent: the
    /// new entry's pending notification should appear in snapshot 2,
    /// so a truly-new send always survives; an addition with no
    /// references is suspicious anyway.
    func testUnreferencedDynamicAdditionIsStillPruned() {
        let dynUnreferenced = category("roar.dyn.orphan")
        let categories1: Set<UNNotificationCategory> = []
        let categories2: Set<UNNotificationCategory> = [dynUnreferenced]
        let result = Clear.mergePrunedCategories(
            categories1: categories1,
            categories2: categories2,
            referenced1: [],
            referenced2: []
        )
        XCTAssertTrue(result.isEmpty,
                      "Unreferenced dynamic additions are not exempt from the prune rule")
    }

    /// A non-dynamic addition (any identifier not starting with
    /// `roar.dyn.`) is always preserved, regardless of references —
    /// matches `filterPrunedCategories`'s prefix-only scope.
    func testNonDynamicAdditionAlwaysSurvives() {
        let userAdd = category("user.added-during-gap")
        let categories1: Set<UNNotificationCategory> = []
        let categories2: Set<UNNotificationCategory> = [userAdd]
        let result = Clear.mergePrunedCategories(
            categories1: categories1,
            categories2: categories2,
            referenced1: [],
            referenced2: []
        )
        XCTAssertEqual(result, [userAdd])
    }

    /// References from EITHER snapshot keep a category alive. A
    /// pending notification that was present in snapshot 1 but
    /// cleared by some external actor before snapshot 2 still
    /// counts — the orchestrator's only writes are
    /// `setNotificationCategories`, so the union is the safe
    /// interpretation of "in use during the prune window."
    func testReferenceFromEitherSnapshotKeepsCategoryAlive() {
        let dynA = category("roar.dyn.refed-in-snap1")
        let dynB = category("roar.dyn.refed-in-snap2")
        let categories1: Set<UNNotificationCategory> = [dynA, dynB]
        let categories2: Set<UNNotificationCategory> = [dynA, dynB]
        let result = Clear.mergePrunedCategories(
            categories1: categories1,
            categories2: categories2,
            referenced1: ["roar.dyn.refed-in-snap1"],
            referenced2: ["roar.dyn.refed-in-snap2"]
        )
        // Both kept — neither snapshot alone would have kept both,
        // but the union does.
        XCTAssertEqual(result, [dynA, dynB])
    }

    /// A `roar.dyn.*` category that became referenced in snapshot 2
    /// (e.g. the same concurrent-send scenario but the new
    /// notification's category identifier matches an existing
    /// stale entry — the entry is revived). Pin that revival
    /// works.
    func testStaleDynamicCategoryRevivedByNewReferenceIsKept() {
        let dyn = category("roar.dyn.aaa")
        let categories1: Set<UNNotificationCategory> = [dyn]
        let categories2: Set<UNNotificationCategory> = [dyn]
        let result = Clear.mergePrunedCategories(
            categories1: categories1,
            categories2: categories2,
            referenced1: [],
            referenced2: ["roar.dyn.aaa"]
        )
        XCTAssertEqual(result, [dyn])
    }
}
