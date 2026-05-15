import XCTest
@testable import roar

/// Pin which `--*` flags trigger the "delivered quietly under
/// provisional authorization" stderr warning. The helper is a pure
/// function over the flag bag; the surrounding code is just a
/// settings round-trip and a stderr write.
final class ProvisionalDowngradeWarningTests: XCTestCase {

    func testNoFlagsSetReturnsEmpty() {
        // Plain `roar send --body x` with no loud affordances: nothing
        // to warn about, so the helper returns empty and the call site
        // skips the settings round-trip.
        XCTAssertEqual(
            Send.affordancesDowngradedByProvisional(
                sound: nil, interruptionLevel: nil),
            []
        )
    }

    func testSoundAlone() {
        XCTAssertEqual(
            Send.affordancesDowngradedByProvisional(
                sound: "default", interruptionLevel: nil),
            ["--sound"]
        )
    }

    func testTimeSensitiveAlone() {
        XCTAssertEqual(
            Send.affordancesDowngradedByProvisional(
                sound: nil, interruptionLevel: .timeSensitive),
            ["--interruption-level time-sensitive"]
        )
    }

    func testPassiveAndActiveDoNotWarn() {
        // `.passive` is already quiet by design; `.active` is the
        // default level. Neither is an explicit opt-in to a louder
        // affordance, so the helper deliberately ignores them.
        XCTAssertEqual(
            Send.affordancesDowngradedByProvisional(
                sound: nil, interruptionLevel: .passive),
            []
        )
        XCTAssertEqual(
            Send.affordancesDowngradedByProvisional(
                sound: nil, interruptionLevel: .active),
            []
        )
    }

    func testBothProduceStableOrder() {
        // The order in the warning string is `--sound`, then
        // interruption level — stable so users grepping for
        // "warning: --sound" don't have to handle a rearranged list.
        XCTAssertEqual(
            Send.affordancesDowngradedByProvisional(
                sound: "Glass", interruptionLevel: .timeSensitive),
            ["--sound", "--interruption-level time-sensitive"]
        )
    }
}
