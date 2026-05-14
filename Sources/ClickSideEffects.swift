import AppKit
import Foundation

/// Side-effect helpers invoked from `RoarAppDelegate.handleActivation`
/// when a user clicks a notification.
///
/// These were previously instance methods on `RoarAppDelegate` even
/// though they touch no instance state — extracted to a free-
/// function namespace so the delegate file (which already has
/// click-routing, UN delegate, wait-mode subscription, exit
/// scheduling, and runloop-lifecycle concerns) stays focused on
/// orchestration. The activation poll + URL open + debug stderr
/// helpers all read environment / call AppKit / write to FileHandle
/// — no `self` state, no main-actor isolation requirement beyond
/// the AppKit API they call.
///
/// `enum` (uninstantiable) so callers always use the static API;
/// `nonisolated` because callers reach in from the delegate's
/// `@MainActor` context and from `ShellExecutor.runShell`'s
/// detached watchdog body.
enum ClickSideEffects {

    /// Maximum time to wait for an `--activate-bundle-id` target to
    /// actually become the foreground app.
    /// `NSWorkspace.openApplication` returns when the launch is
    /// *accepted*, not when activation completes — without this
    /// poll, `RoarAppDelegate.exitDrainDelay` (sized for the UN
    /// XPC ack, not the workspace handshake) can fire before the
    /// target is frontmost.
    nonisolated static let activationConfirmDeadline: Duration = .seconds(2)

    /// Poll interval while waiting for the activated app to surface.
    nonisolated static let activationConfirmPollInterval: Duration = .milliseconds(50)

    /// Re-parse and dispatch the click-time URL.
    ///
    /// The send-time allow-list (`--allow-url-scheme`) is replayed
    /// via the `roar.open.allowedSchemes` userInfo field so the
    /// click handler never broadens what the user opted into at
    /// send time. A `nil` `allowedSchemes` (missing / malformed
    /// userInfo blob) falls back to `URLValidation.defaultOpenSchemes`
    /// — strictly narrower than any user-extended set, i.e.
    /// fails-closed.
    ///
    /// - Parameters:
    ///   - raw: The userInfo `roar.open.url` string.
    ///   - allowedSchemes: The deserialised allow-list from
    ///     `roar.open.allowedSchemes`, or `nil` to use defaults.
    /// - Returns: `true` if `NSWorkspace` accepted the URL for opening.
    @MainActor
    static func openClickURL(
        _ raw: String, allowedSchemes: Set<String>?
    ) -> Bool {
        let effective = allowedSchemes ?? URLValidation.defaultOpenSchemes
        do {
            let url = try URLValidation.parse(
                raw, allowedSchemes: effective)
            return NSWorkspace.shared.open(url)
        } catch {
            // Raw URL may contain credentials in `user:pass@host` or
            // tokens in the query string; the click handler runs
            // under launchd, so unconditional stderr ends up in the
            // unified log. Show details only under ROAR_DEBUG.
            debugOrBriefStderr(
                detail: "Refusing to open '\(raw)': \(error.localizedDescription)\n",
                brief: "Refused to open notification URL (set ROAR_DEBUG for details).\n"
            )
            return false
        }
    }

    /// Bring the application with the given bundle identifier to the
    /// foreground.
    ///
    /// `NSWorkspace.openApplication(at:configuration:)` returns the
    /// instant the launch is *accepted* — for a cold target the
    /// app may still be initialising. Without an additional wait,
    /// the post-exit drain (sized for the UN XPC ack, not the
    /// workspace handshake) can fire before the target is
    /// frontmost, especially when the click came in while a slow
    /// app like Xcode was loading. Poll `NSRunningApplication.isActive`
    /// up to `activationConfirmDeadline` and only then return.
    ///
    /// - Parameter bundleID: The bundle identifier of the target app.
    /// - Returns: `true` if the app could be located and launched.
    ///   `isActive` confirmation is best-effort — still returns
    ///   `true` if launch succeeded but activation hasn't surfaced
    ///   within the deadline (some apps refuse to activate, e.g.
    ///   background helpers).
    @MainActor
    static func activateApp(bundleID: String) async -> Bool {
        let workspace = NSWorkspace.shared
        guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            // Bundle id is user-supplied at send time and persists in
            // userInfo; suppress under launchd by default for the same
            // reason as `openClickURL`.
            debugOrBriefStderr(
                detail: "Unable to find an application with bundle identifier '\(bundleID)'.\n",
                brief: "Activate target not found (set ROAR_DEBUG for details).\n"
            )
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            let running = try await workspace.openApplication(at: url, configuration: config)
            await waitForActivation(of: running)
            return true
        } catch {
            debugOrBriefStderr(
                detail: "Failed to activate '\(bundleID)': \(error.localizedDescription)\n",
                brief: "Failed to activate target application (set ROAR_DEBUG for details).\n"
            )
            return false
        }
    }

    /// Poll an `NSRunningApplication` until it reports `isActive` or
    /// the deadline elapses. Runs on the main actor (cheap KVO-ish
    /// property reads) and yields between iterations via
    /// `Task.sleep`, so the runloop keeps draining.
    ///
    /// - Parameter running: The instance returned by
    ///   `workspace.openApplication`.
    @MainActor
    static func waitForActivation(of running: NSRunningApplication) async {
        let deadline = ContinuousClock.now.advanced(by: activationConfirmDeadline)
        while ContinuousClock.now < deadline {
            if running.isActive { return }
            try? await Task.sleep(for: activationConfirmPollInterval)
        }
    }

    /// Write `message` to stderr only when `ROAR_DEBUG` is set in
    /// the environment. Centralises the env-var check so it isn't
    /// repeated at every call site and so a future "log to file"
    /// mode can be added in one place. The env-var read is
    /// intentionally per-call rather than cached so a parent that
    /// exports `ROAR_DEBUG` mid-run (rare, but possible in tests)
    /// takes effect immediately.
    ///
    /// `nonisolated` because `ShellExecutor.runShell`'s
    /// `Task.detached` body calls it (via closure injection)
    /// without an actor hop; `ProcessInfo` and `FileHandle` writes
    /// are safe from any thread.
    nonisolated static func debugStderr(_ message: String) {
        guard ProcessInfo.processInfo.environment["ROAR_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data(message.utf8))
    }

    /// Emit a diagnostic to stderr: the verbose `detail` when
    /// `ROAR_DEBUG` is set, otherwise the credential-safe `brief`.
    /// This is the right shape for failures whose detail may
    /// contain user-supplied URLs / commands / bundle ids
    /// (credentials in query strings, tokens in basic-auth) —
    /// under launchd, stderr lands in the unified log, so the
    /// brief form is the safe default and the detail form is
    /// gated by explicit env-var opt-in.
    ///
    /// Either one OR the other of the two messages is written.
    /// Both end in `\n` by convention to keep call sites tidy.
    nonisolated static func debugOrBriefStderr(detail: String, brief: String) {
        let isDebug = ProcessInfo.processInfo.environment["ROAR_DEBUG"] != nil
        let payload = isDebug ? detail : brief
        FileHandle.standardError.write(Data(payload.utf8))
    }
}
