import XCTest
import UserNotifications
@testable import roar

/// Pinned behaviour for `Settings.format(...)`. The single-arg overload
/// that takes a real `UNNotificationSettings` can't be tested directly
/// (the class has no public initialiser), so the formatter is exposed
/// via a field-by-field overload that tests drive with synthetic
/// values.
final class SettingsFormatTests: XCTestCase {

    // MARK: - Enum token rendering

    func testAuthorizationStatusTokens() {
        // `.ephemeral` is marked unavailable on macOS — the formatter
        // still handles the case for exhaustiveness (the pattern label
        // is valid even if the explicit value is not constructible at
        // call sites), but the test can't exercise it directly here.
        XCTAssertEqual(Settings.format(status: .notDetermined), "not-determined")
        XCTAssertEqual(Settings.format(status: .denied), "denied")
        XCTAssertEqual(Settings.format(status: .authorized), "authorized")
        XCTAssertEqual(Settings.format(status: .provisional), "provisional")
    }

    func testSettingTokens() {
        XCTAssertEqual(Settings.format(setting: .notSupported), "not-supported")
        XCTAssertEqual(Settings.format(setting: .disabled), "disabled")
        XCTAssertEqual(Settings.format(setting: .enabled), "enabled")
    }

    func testAlertStyleTokens() {
        XCTAssertEqual(Settings.format(style: .none), "none")
        XCTAssertEqual(Settings.format(style: .banner), "banner")
        XCTAssertEqual(Settings.format(style: .alert), "alert")
    }

    func testShowPreviewsTokens() {
        XCTAssertEqual(Settings.format(previews: .always), "always")
        XCTAssertEqual(Settings.format(previews: .whenAuthenticated),
                       "when-authenticated")
        XCTAssertEqual(Settings.format(previews: .never), "never")
    }

    // MARK: - Full formatter

    func testFullOutputShape() {
        let output = Settings.format(
            authorizationStatus: .authorized,
            alertSetting: .enabled,
            alertStyle: .banner,
            soundSetting: .enabled,
            badgeSetting: .disabled,
            lockScreenSetting: .enabled,
            notificationCenterSetting: .enabled,
            criticalAlertSetting: .notSupported,
            showPreviewsSetting: .whenAuthenticated,
            timeSensitiveSetting: .enabled,
            scheduledDeliverySetting: .disabled,
            directMessagesSetting: .notSupported,
            providesAppNotificationSettings: false
        )
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // Exactly 13 lines, one per field.
        XCTAssertEqual(lines.count, 13)
        XCTAssertEqual(lines[0], "authorization-status: authorized")
        XCTAssertEqual(lines[1], "alert-setting: enabled")
        XCTAssertEqual(lines[2], "alert-style: banner")
        XCTAssertEqual(lines[3], "sound-setting: enabled")
        XCTAssertEqual(lines[4], "badge-setting: disabled")
        XCTAssertEqual(lines[5], "lock-screen-setting: enabled")
        XCTAssertEqual(lines[6], "notification-center-setting: enabled")
        XCTAssertEqual(lines[7], "critical-alert-setting: not-supported")
        XCTAssertEqual(lines[8], "show-previews-setting: when-authenticated")
        XCTAssertEqual(lines[9], "time-sensitive-setting: enabled")
        XCTAssertEqual(lines[10], "scheduled-delivery-setting: disabled")
        XCTAssertEqual(lines[11], "direct-messages-setting: not-supported")
        XCTAssertEqual(lines[12], "provides-app-notification-settings: false")
    }

    func testProvidesAppSettingsTrueRendered() {
        let output = Settings.format(
            authorizationStatus: .denied,
            alertSetting: .disabled,
            alertStyle: .none,
            soundSetting: .disabled,
            badgeSetting: .disabled,
            lockScreenSetting: .disabled,
            notificationCenterSetting: .disabled,
            criticalAlertSetting: .disabled,
            showPreviewsSetting: .never,
            timeSensitiveSetting: .disabled,
            scheduledDeliverySetting: .disabled,
            directMessagesSetting: .disabled,
            providesAppNotificationSettings: true
        )
        XCTAssertTrue(
            output.contains("provides-app-notification-settings: true"))
    }

    func testDirectMessagesRendered() {
        // `directMessagesSetting` is macOS 14+ UN-specific
        // introspection (whether the user has scoped this app's
        // communication notifications to a Focus filter). Verify the
        // formatter emits it with the expected token.
        let output = Settings.format(
            authorizationStatus: .authorized,
            alertSetting: .enabled,
            alertStyle: .banner,
            soundSetting: .enabled,
            badgeSetting: .enabled,
            lockScreenSetting: .enabled,
            notificationCenterSetting: .enabled,
            criticalAlertSetting: .disabled,
            showPreviewsSetting: .always,
            timeSensitiveSetting: .enabled,
            scheduledDeliverySetting: .enabled,
            directMessagesSetting: .disabled,
            providesAppNotificationSettings: false
        )
        XCTAssertTrue(output.contains("direct-messages-setting: disabled"))
    }
}
