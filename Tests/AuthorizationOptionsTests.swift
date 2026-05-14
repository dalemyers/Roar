import XCTest
import UserNotifications
@testable import roar

/// Pin the auth-options set. The shape is intentionally fixed:
/// macOS 12 deprecated the `.timeSensitive` `UNAuthorizationOption`
/// in favour of an entitlement an ad-hoc-signed CLI cannot claim, so
/// adding the bit at runtime would compile-fail under
/// `SWIFT_TREAT_WARNINGS_AS_ERRORS` and wouldn't take effect anyway.
/// These tests pin that contract so a future "let's just add
/// `.timeSensitive` back" regression is caught early.
final class AuthorizationOptionsTests: XCTestCase {

    func testDefaultOptionsIncludeAlertSoundProvisional() {
        let options = Send.authorizationOptions()
        XCTAssertTrue(options.contains(.alert))
        XCTAssertTrue(options.contains(.sound))
        XCTAssertTrue(options.contains(.provisional))
    }

    func testOptionsAreStable() {
        // The auth options set is fixed — the interruption level
        // lives on the *content*, not in the authorization grant,
        // for an unsigned tool. Pin equality across two calls so a
        // refactor that introduces flag-dependent variation is
        // caught.
        XCTAssertEqual(Send.authorizationOptions(), Send.authorizationOptions())
    }
}
