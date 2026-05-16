import Darwin
import Foundation
import UserNotifications

extension Send {
    /// Ensure the user has granted notification permission. Distinguishes
    /// "never asked" (request, may prompt) from "previously denied"
    /// (skip the request and tell the user where to flip the switch).
    ///
    /// - Throws: errors thrown by `requestAuthorization`. Exits non-zero
    ///   with a user-facing message on explicit denial.
    func ensureAuthorized(center: UNUserNotificationCenter) async throws {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return
        case .denied:
            let msg = "Notification permission was previously denied. Re-enable it in System Settings → Notifications → Roar.\n"
            FileHandle.standardError.write(Data(msg.utf8))
            // Route through the shared exit chokepoint so the
            // denial path is testable through the same `CommandExit.hook`
            // that the success paths use. The previous direct
            // `Darwin.exit(1)` bypassed the hook entirely, leaving
            // the denied branch with zero test coverage and (per
            // LEARNINGS.md) skipping any pending Swift `defer`
            // unwinds — both real risks if a future caller adds
            // cleanup between the auth check and the `add(_:)`
            // call.
            await CommandExit.perform(
                CommandExit.Plan(drain: .zero, code: 1))
        case .notDetermined:
            try await requestAuthorizationOrExit(center: center)
        @unknown default:
            // Unknown future status — try the request and honour the
            // result the same way as `.notDetermined`. Discarding
            // `granted` (as the previous implementation did) would let
            // `send` proceed and call `center.add(_:)` even when a new
            // status semantically means "denied," producing a silent
            // failure with no notification surfaced.
            try await requestAuthorizationOrExit(center: center)
        }
    }

    /// Build the `UNAuthorizationOptions` set used in `requestAuthorization`.
    /// Always includes `.alert`, `.sound`, and `.provisional`.
    ///
    /// Time-sensitive break-through is not surfaced through
    /// `UNAuthorizationOptions` at all — the public option set is
    /// `.alert`, `.badge`, `.sound`, `.carPlay`, `.criticalAlert`,
    /// `.providesAppNotificationSettings`, and `.provisional`, with
    /// no time-sensitive entry. The gating mechanism is the
    /// `com.apple.developer.usernotifications.time-sensitive`
    /// entitlement, which Apple gates behind paid developer
    /// approval and Roar's minimal entitlement set deliberately
    /// does not claim. `--interruption-level time-sensitive` is
    /// still wired through to `content.interruptionLevel` because
    /// it works as a *hint* to the framework — passive levels
    /// still demote correctly, and a future build that claims the
    /// entitlement gets break-through behaviour without touching
    /// this call site.
    ///
    /// `nonisolated static` so tests can pin the rule without
    /// invoking the real authorization API.
    static func authorizationOptions() -> UNAuthorizationOptions {
        return [.alert, .sound, .provisional]
    }

    /// Enumerate the affordances that macOS silently downgrades under
    /// provisional authorization, given the user's flag selection. The
    /// caller uses the result to decide whether to emit the
    /// "delivered quietly" warning — an empty array means nothing was
    /// going to be loud anyway, so the warning would be noise.
    ///
    /// Provisional auth allows the post to land in Notification
    /// Center quietly but suppresses:
    ///
    ///   * sound (any `--sound` value, including `default`)
    ///   * banner break-through for time-sensitive interruption
    ///     (`--interruption-level time-sensitive`)
    ///
    /// `.passive` and `.active` interruption levels are NOT listed:
    /// `.passive` is already quiet by design, and `.active` (the
    /// default) is the level the provisional grant most directly
    /// silences via the no-banner rule — but every `.active` post
    /// would warn, which trains users to ignore the diagnostic. The
    /// loud-affordance signal is "the user explicitly asked for
    /// something more than the default," so we only warn for the
    /// flags that opt into stronger interruption.
    ///
    /// `nonisolated static` so tests can pin the rule without
    /// constructing a real send.
    static func affordancesDowngradedByProvisional(
        sound: String?,
        interruptionLevel: InterruptionLevel?
    ) -> [String] {
        var silenced: [String] = []
        if sound != nil { silenced.append("--sound") }
        if interruptionLevel == .timeSensitive {
            silenced.append("--interruption-level time-sensitive")
        }
        return silenced
    }

    /// Prompt for notification permission and exit non-zero if denied.
    /// Shared between the `.notDetermined` and `@unknown default`
    /// branches of `ensureAuthorized` so the request/refusal handling
    /// only lives in one place.
    ///
    /// `.provisional` is included alongside `.alert`/`.sound` so that
    /// first-run invocations from non-interactive contexts (cron,
    /// LaunchAgent, CI) never block on a permission dialog. Per Apple's
    /// docs, requesting both kinds of authorization makes the system
    /// grant provisional *silently* — `requestAuthorization` returns
    /// `true`, the auth status flips to `.provisional`, and notifications
    /// post quietly to Notification Center (no banner / no sound) until
    /// the user promotes the app via System Settings or the per-notification
    /// "Keep" affordance the first time they interact with one. This
    /// trades the historical "banner on first send" behaviour for "no
    /// modal interruption ever," which fits a CLI tool's launch shape
    /// better — a user who explicitly wanted banners can promote in one
    /// click, while a cron job no longer hangs on an off-screen prompt.
    ///
    /// Time-sensitive break-through is not requested here:
    /// `UNAuthorizationOptions` has no time-sensitive bit (only
    /// `.alert`, `.badge`, `.sound`, `.carPlay`, `.criticalAlert`,
    /// `.providesAppNotificationSettings`, `.provisional`). The
    /// gating mechanism is the
    /// `com.apple.developer.usernotifications.time-sensitive`
    /// entitlement, which Roar's minimal entitlement set does not
    /// claim. See `authorizationOptions()` for the full rationale.
    /// A future build that claims the entitlement can change the
    /// helper without touching this call site.
    func requestAuthorizationOrExit(center: UNUserNotificationCenter) async throws {
        let granted = try await center.requestAuthorization(
            options: Self.authorizationOptions())
        guard granted else {
            let msg = "Notification permission denied. Enable it in System Settings → Notifications → Roar.\n"
            FileHandle.standardError.write(Data(msg.utf8))
            // Route through the shared exit chokepoint — same
            // rationale as `ensureAuthorized` above.
            await CommandExit.perform(
                CommandExit.Plan(drain: .zero, code: 1))
            return
        }
    }
}
