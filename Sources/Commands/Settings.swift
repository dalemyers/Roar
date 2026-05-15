import ArgumentParser
import Darwin
import Foundation
import UserNotifications

/// `roar settings` — print the current `UNNotificationSettings` for
/// this bundle. Useful for debugging "why didn't my notification play a
/// sound" or "is time-sensitive actually allowed under my Focus
/// configuration" without needing to dig through System Settings.
///
/// Output is a stable `key: value` format, one field per line, with
/// kebab-case keys so the output composes with `grep` / `awk` and
/// reads cleanly inline. The exit code is 0 regardless of authorization
/// state — this command is *introspecting*, not asserting; callers
/// who want to gate on a particular state can grep the output.
struct Settings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Print the system's UNNotificationSettings for this bundle."
    )

    /// Fetch the current `UNNotificationSettings` and print the
    /// formatted view to stdout.
    func run() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let output = Self.format(settings: settings)
        print(output)
        await CommandExit.perform(CommandExit.Plan(drain: .zero, code: 0))
    }

    /// Render a `UNNotificationSettings` as the stable `key: value`
    /// output `roar settings` prints. Extracted as `static` so tests
    /// can construct a synthetic settings-like value and assert on the
    /// formatted shape without driving the real notification center.
    ///
    /// Some fields are macOS-12+ (timeSensitive, scheduledDelivery);
    /// the deployment target is 13.0 so they are always available, but
    /// the formatter still uses the `Self.formatSetting` helper for
    /// each so a future deployment-target bump that introduces an
    /// availability gate has a single edit point.
    ///
    /// - Parameter settings: A `UNNotificationSettings` (production)
    ///   or any object whose property shape matches it (tests can
    ///   pass a stub via the `format(authorizationStatus:...)` overload).
    /// - Returns: A newline-joined string with one `key: value` per
    ///   line, terminated by a trailing newline so the next prompt
    ///   sits on a fresh line.
    static func format(settings: UNNotificationSettings) -> String {
        // `directMessagesSetting` is macOS 14+. Read it through an
        // availability gate and pass `.notSupported` on older
        // deployments so the formatter shape stays stable. (Apple's
        // sibling `announcementSetting` is iOS/watchOS only — there
        // is no macOS equivalent to surface here, so it's omitted
        // from the output entirely rather than always emitting
        // `not-supported`.)
        let directMessages: UNNotificationSetting
        if #available(macOS 14.0, *) {
            directMessages = settings.directMessagesSetting
        } else {
            directMessages = .notSupported
        }
        return format(
            authorizationStatus: settings.authorizationStatus,
            alertSetting: settings.alertSetting,
            alertStyle: settings.alertStyle,
            soundSetting: settings.soundSetting,
            lockScreenSetting: settings.lockScreenSetting,
            notificationCenterSetting: settings.notificationCenterSetting,
            criticalAlertSetting: settings.criticalAlertSetting,
            showPreviewsSetting: settings.showPreviewsSetting,
            timeSensitiveSetting: settings.timeSensitiveSetting,
            scheduledDeliverySetting: settings.scheduledDeliverySetting,
            directMessagesSetting: directMessages,
            providesAppNotificationSettings: settings.providesAppNotificationSettings
        )
    }

    /// Field-by-field overload used by the tests so they can drive the
    /// formatter without constructing a real `UNNotificationSettings`
    /// (the class has no public initialiser). The production caller
    /// is the single-arg overload above.
    ///
    /// `directMessagesSetting` is macOS 14+ and reports whether the
    /// user has scoped this app's communication notifications to a
    /// Focus filter — for older deployments the production wrapper
    /// passes `.notSupported` so the output shape doesn't shift
    /// between OS versions.
    static func format(
        authorizationStatus: UNAuthorizationStatus,
        alertSetting: UNNotificationSetting,
        alertStyle: UNAlertStyle,
        soundSetting: UNNotificationSetting,
        lockScreenSetting: UNNotificationSetting,
        notificationCenterSetting: UNNotificationSetting,
        criticalAlertSetting: UNNotificationSetting,
        showPreviewsSetting: UNShowPreviewsSetting,
        timeSensitiveSetting: UNNotificationSetting,
        scheduledDeliverySetting: UNNotificationSetting,
        directMessagesSetting: UNNotificationSetting,
        providesAppNotificationSettings: Bool
    ) -> String {
        let lines: [String] = [
            "authorization-status: \(format(status: authorizationStatus))",
            "alert-setting: \(format(setting: alertSetting))",
            "alert-style: \(format(style: alertStyle))",
            "sound-setting: \(format(setting: soundSetting))",
            "lock-screen-setting: \(format(setting: lockScreenSetting))",
            "notification-center-setting: \(format(setting: notificationCenterSetting))",
            "critical-alert-setting: \(format(setting: criticalAlertSetting))",
            "show-previews-setting: \(format(previews: showPreviewsSetting))",
            "time-sensitive-setting: \(format(setting: timeSensitiveSetting))",
            "scheduled-delivery-setting: \(format(setting: scheduledDeliverySetting))",
            "direct-messages-setting: \(format(setting: directMessagesSetting))",
            "provides-app-notification-settings: \(providesAppNotificationSettings)",
        ]
        return lines.joined(separator: "\n")
    }

    /// Render `UNAuthorizationStatus` as a stable kebab-case token.
    /// The Apple enum's `description` is `Int`-backed and would
    /// produce numbers, which are useless to a shell pipeline. The
    /// `@unknown default` falls back to "unknown" so a future case
    /// (e.g. iOS 17 added `.ephemeral`) doesn't break the formatter.
    static func format(status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not-determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    /// Render `UNNotificationSetting` (the per-affordance enable
    /// state) as a stable kebab-case token. `notSupported` is what the
    /// framework returns for affordances irrelevant on the current
    /// platform (e.g. `lockScreenSetting` on early macOS versions).
    static func format(setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: return "not-supported"
        case .disabled: return "disabled"
        case .enabled: return "enabled"
        @unknown default: return "unknown"
        }
    }

    /// Render `UNAlertStyle` — the user's "Banner" / "Alert" /
    /// "None" choice in System Settings.
    static func format(style: UNAlertStyle) -> String {
        switch style {
        case .none: return "none"
        case .banner: return "banner"
        case .alert: return "alert"
        @unknown default: return "unknown"
        }
    }

    /// Render `UNShowPreviewsSetting` — whether notification previews
    /// are shown always / when-unlocked / never.
    static func format(previews: UNShowPreviewsSetting) -> String {
        switch previews {
        case .always: return "always"
        case .whenAuthenticated: return "when-authenticated"
        case .never: return "never"
        @unknown default: return "unknown"
        }
    }
}
