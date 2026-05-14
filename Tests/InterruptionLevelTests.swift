import XCTest
import ArgumentParser
import UserNotifications
@testable import roar

/// Pin the `--interruption-level` argument parsing and UN mapping.
///
/// The CLI exposes three of the four `UNNotificationInterruptionLevel`
/// cases (`.passive`, `.active`, `.timeSensitive`); `.critical` is
/// intentionally not surfaced because it requires Apple-granted
/// entitlement that an ad-hoc-signed CLI never has.
final class InterruptionLevelTests: XCTestCase {

    func testPassiveParses() throws {
        let level = Send.InterruptionLevel(argument: "passive")
        XCTAssertEqual(level, .passive)
        XCTAssertEqual(level?.unValue, .passive)
    }

    func testActiveParses() throws {
        let level = Send.InterruptionLevel(argument: "active")
        XCTAssertEqual(level, .active)
        XCTAssertEqual(level?.unValue, .active)
    }

    func testTimeSensitiveParses() throws {
        let level = Send.InterruptionLevel(argument: "time-sensitive")
        XCTAssertEqual(level, .timeSensitive)
        XCTAssertEqual(level?.unValue, .timeSensitive)
    }

    func testCriticalRejected() {
        // `.critical` is an Apple-entitled level. Surface a parse
        // failure rather than silently degrading.
        XCTAssertNil(Send.InterruptionLevel(argument: "critical"))
    }

    func testTypoRejected() {
        XCTAssertNil(Send.InterruptionLevel(argument: "timesensitive"))
        XCTAssertNil(Send.InterruptionLevel(argument: "TIME_SENSITIVE"))
        XCTAssertNil(Send.InterruptionLevel(argument: ""))
    }

    func testAllCasesExposed() {
        // Sanity check that CaseIterable enumerates exactly the three
        // user-facing values. If a future contributor adds `.critical`,
        // this will fail and force them to reconsider the entitlement
        // implications.
        XCTAssertEqual(
            Set(Send.InterruptionLevel.allCases.map(\.rawValue)),
            ["passive", "active", "time-sensitive"]
        )
    }
}
