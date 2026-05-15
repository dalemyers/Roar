import Foundation
import UserNotifications

extension Send {
    /// Bundle of values extracted from a `UNNotificationResponse`
    /// before being handed to `exitFromWait`. The helper takes this
    /// rather than the `UNNotificationResponse` itself because the
    /// framework type is sealed (no public initialiser), and tests
    /// need to drive the wait-exit branch end-to-end through the
    /// exit hook.
    struct WaitExitPrimitives: Sendable, Equatable {
        let actionIdentifier: String
        let userText: String?
    }

    /// Print the `--wait` terminal output (or the timeout sentinel)
    /// and route to `performExit`. Pulled out of `run` so the call
    /// site can be exercised in tests via `Send.exitHook` without
    /// needing to mock UN.
    ///
    /// Branches:
    /// * `primitives` non-nil — a real click. The print payload
    ///   matches `formatWaitResponse`; the drain matches
    ///   `exitDrainDelay` so the XPC click ack is flushed before
    ///   `Darwin.exit`. Exit code is `outcome.exitCode`: 0 for the
    ///   default click and custom actions, `waitDismissExitCode` (3)
    ///   when the user explicitly dismissed. The split lets shell
    ///   scripts distinguish "user engaged" from "user rejected"
    ///   without parsing stdout.
    /// * `primitives` nil — `cancelWait()` fired (timeout). Print
    ///   the `waitTimeoutSentinel`, drain zero (the timeout path
    ///   never fired a UN completion handler so there is no XPC
    ///   reply to flush — `usernoted` is not waiting on us), exit
    ///   code `waitTimeoutExitCode`.
    ///
    /// `nonisolated static` so the test seam doesn't pull
    /// `MainActor` isolation across the call.
    ///
    /// - Parameters:
    ///   - primitives: The matched response's action + user-text,
    ///     or `nil` on the timeout path.
    ///   - json: When true, emit the JSON shape (`WaitJSONShape`)
    ///     instead of the text protocol. Exit code is unchanged —
    ///     0 / 2 / 3 still distinguish click vs timeout vs
    ///     dismiss, so scripts that branch on `$?` work
    ///     identically across formats.
    static func exitFromWait(primitives: WaitExitPrimitives?, json: Bool = false) async {
        if let primitives {
            let outcome = Self.formatWaitResponse(
                actionIdentifier: primitives.actionIdentifier,
                userText: primitives.userText
            )
            if json {
                print(encodeJSON(WaitJSONShape(
                    outcome: outcome.exitCode == waitDismissExitCode ? "dismiss" : "click",
                    action: primitives.actionIdentifier,
                    text: primitives.userText
                )))
            } else {
                print(outcome.output, terminator: "")
            }
            await Self.performExit(
                ExitPlan(drain: outcome.drain, code: outcome.exitCode))
            return
        }
        if json {
            print(encodeJSON(WaitJSONShape(
                outcome: "timeout",
                action: waitTimeoutSentinel,
                text: nil
            )))
        } else {
            print(Self.waitTimeoutSentinel)
        }
        await Self.performExit(
            ExitPlan(drain: .zero, code: Self.waitTimeoutExitCode))
    }

    /// JSON shape for `roar send --wait --json`. Three fields:
    ///
    ///   - `outcome`: one of `click` / `dismiss` / `timeout`. The
    ///     coarse-grained verdict — most scripts that wanted a
    ///     `case` over the four text-protocol shapes can switch
    ///     on this alone.
    ///   - `action`: the action identifier (`default`, the user's
    ///     `--action <id>:<title>` id, or `dismiss` / `timeout` for
    ///     those outcomes). Same sentinel vocabulary as the text
    ///     protocol so a translation table isn't needed.
    ///   - `text`: the `--text-action` typed text, or `null` for
    ///     non-text-action outcomes. JSON string-escaping means
    ///     embedded newlines / control bytes survive cleanly;
    ///     the text protocol relied on "read to EOF" semantics
    ///     for the same.
    ///
    /// Exit codes are unchanged across output modes
    /// (`waitDismissExitCode` = 3, `waitTimeoutExitCode` = 2,
    /// success = 0). Scripts using `$?` work identically; scripts
    /// using `jq -r '.outcome'` get a single token to switch on.
    struct WaitJSONShape: Encodable, Equatable {
        let outcome: String
        let action: String
        let text: String?

        enum CodingKeys: String, CodingKey {
            case outcome, action, text
        }

        // Custom encode to emit `"text": null` rather than omit
        // the key when text is nil. The ABI is "every field
        // appears in every emission" so a `jq '.text'` always
        // returns a value (null vs string), letting consumers
        // distinguish "click had no text" from "key spelling
        // changed".
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(outcome, forKey: .outcome)
            try c.encode(action, forKey: .action)
            try c.encode(text, forKey: .text)
        }
    }

    /// Terminal output, post-print drain duration, and exit code for
    /// a `--wait` click that resumed with a real response (not a
    /// timeout). The fields are emitted in `run()` as:
    ///
    /// ```
    /// print(outcome.output, terminator: "")
    /// try? await Task.sleep(for: outcome.drain)
    /// Darwin.exit(outcome.exitCode)
    /// ```
    ///
    /// `output` carries its own trailing newline(s) — one after the
    /// action id, plus, when present, the user-typed text verbatim.
    /// Using `terminator: ""` at the call site lets this struct own
    /// the entire byte layout, so test assertions can pin the exact
    /// bytes a downstream shell consumer will see.
    ///
    /// `drain` is non-zero for every real click outcome to match the
    /// `scheduleExit` behaviour on the non-wait path; both paths ack
    /// a UN completion handler whose XPC reply flushes asynchronously.
    ///
    /// `exitCode` is 0 for default-click and custom-action responses,
    /// `waitDismissExitCode` (3) when the user explicitly dismissed.
    /// Pre-fix the dismiss case shared exit code 0 with the
    /// default-click case and scripts had to parse stdout to tell
    /// them apart; the dedicated code lets shells branch on `$?`.
    struct WaitTerminalOutcome: Sendable, Equatable {
        let output: String
        let drain: Duration
        let exitCode: Int32
    }

    /// Pure helper that pairs the printable representation of a
    /// terminal `--wait` response with the drain duration the caller
    /// must honour before `Darwin.exit`-ing.
    ///
    /// Factored out of `run()` so tests can pin both the exact byte
    /// layout *and* the contract that the drain is at least
    /// `exitDrainDelay` — without those tests, a refactor could
    /// silently drop the post-print sleep and reintroduce the XPC
    /// flush race that `scheduleExit` fixes on the non-wait path.
    ///
    /// The action id and user text are accepted as primitives rather
    /// than via `UNNotificationResponse` because that class is sealed
    /// (no public initialiser) and cannot be constructed in tests.
    /// `Send.exitFromWait` extracts both via `printableActionID(from:)`
    /// and `textInputResponseText(from:)` immediately before calling
    /// this helper.
    ///
    /// - Parameters:
    ///   - actionIdentifier: The user-facing action label, already
    ///     mapped through `printableActionID(from:)` (i.e. the
    ///     framework's reverse-DNS default/dismiss constants have
    ///     been collapsed to `waitDefaultSentinel`/`waitDismissSentinel`,
    ///     and custom action ids pass through verbatim). The mapping
    ///     is single-sourced in `printableActionID` to keep this
    ///     helper free of action-id case logic.
    ///   - userText: The user-typed text for `UNTextInputNotificationResponse`s,
    ///     or `nil` for a plain default/dismiss response.
    /// - Returns: The terminal output and the post-print drain.
    static func formatWaitResponse(
        actionIdentifier: String,
        userText: String?
    ) -> WaitTerminalOutcome {
        // `actionIdentifier` is already a user-facing label thanks
        // to `printableActionID` — no extra mapping needed here.
        var output = "\(actionIdentifier)\n"
        // The user-typed value can contain newlines / NUL bytes / any
        // UTF-8; embed it verbatim so receivers see exactly what the
        // user typed. The trailing newline matches the previous
        // `print` behaviour so existing consumers reading until EOF
        // see no byte-level change apart from the post-print drain.
        if let userText {
            output += "\(userText)\n"
        }
        // Dismiss is the only response shape that maps to a non-zero
        // exit code: the user actively rejected the notification, and
        // shell scripts want `$?` to distinguish that from "the user
        // clicked through" or "a custom button fired." Custom action
        // ids pass through verbatim via `printableActionID`, so the
        // comparison is against `waitDismissSentinel` (the short
        // user-facing label) — the framework's reverse-DNS dismiss
        // constant has already been collapsed by the caller.
        let exitCode: Int32 = (actionIdentifier == waitDismissSentinel)
            ? waitDismissExitCode
            : 0
        return WaitTerminalOutcome(
            output: output,
            drain: RoarAppDelegate.exitDrainDelay,
            exitCode: exitCode
        )
    }

    /// Wrap `delegate.awaitNextResponse()` with an optional
    /// `--wait-timeout`. When `timeoutSeconds` is `nil`, this is
    /// indistinguishable from awaiting directly. Otherwise it races
    /// the await against a timeout Task that calls
    /// `delegate.cancelWait()` on expiry — the delegate's continuation
    /// then resumes with `nil`, which propagates up to the caller as
    /// the timeout signal.
    ///
    /// The caller supplies the already-parsed `TimeInterval` produced
    /// by `validateWaitTimeout`. Parsing happens once at validation
    /// time; the consumer never re-parses the raw `--wait-timeout`
    /// string. This eliminates a previous defence-in-depth `try?`
    /// fallback that would silently disable the timeout on a re-parse
    /// failure, which made the failure mode "the CI job hangs forever"
    /// instead of "the validator rejects the input."
    ///
    /// Cancelling the timeout Task after a normal completion is the
    /// inverse: the sleep throws on cancellation, we don't reach
    /// `cancelWait`, and the delegate is already idle. Main-actor
    /// mutual exclusion between `routeResponse` (which sets
    /// `waitContinuation = nil`) and `cancelWait` (which checks the
    /// same field) keeps the double-resume window closed without an
    /// explicit lock.
    ///
    /// - Parameters:
    ///   - delegate: The shared app delegate that buffers the response.
    ///   - timeoutSeconds: Parsed timeout in seconds, or `nil` for an
    ///     unbounded await. A non-positive value is treated as `nil`
    ///     (defence-in-depth: the validator floor guarantees positive
    ///     intervals, but if a future caller injects a zero we want
    ///     "no timeout" rather than "fire immediately").
    /// - Returns: The user's response, or `nil` if the timeout fired.
    static func awaitResponseWithOptionalTimeout(
        delegate: RoarAppDelegate,
        timeoutSeconds: TimeInterval?
    ) async -> UNNotificationResponse? {
        guard let timeoutSeconds, timeoutSeconds > 0 else {
            return await delegate.awaitNextResponse()
        }
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            // If the sleep was cancelled by the post-await `cancel()`
            // below, the `try?` swallows the error and we fall through
            // here. Re-check cancellation so we don't fire `cancelWait`
            // after the response already drained — that would be a
            // no-op but a confusing one in logs.
            guard !Task.isCancelled else { return }
            delegate.cancelWait()
        }
        let response = await delegate.awaitNextResponse()
        timeoutTask.cancel()
        return response
    }

    /// Translate a `UNNotificationResponse`'s `actionIdentifier` into
    /// the string we print on stdout for `--wait` consumers. The
    /// framework's `UNNotificationDefaultActionIdentifier` /
    /// `UNNotificationDismissActionIdentifier` constants are
    /// reverse-DNS strings (`com.apple.UNNotificationDefaultActionIdentifier`)
    /// — leaking those into a shell script's `case` arms is brittle if
    /// Apple ever renames them, so we map to the short `default` /
    /// `dismiss` sentinels documented in `--wait`'s help text.
    ///
    /// Custom actions pass through verbatim — the action id is
    /// already screened by `parseActions` for whitespace / control
    /// characters / reserved sentinels, so the value is safe to print.
    static func printableActionID(from response: UNNotificationResponse) -> String {
        // Forward to the string-taking overload so the mapping
        // policy is single-sourced and directly unit-testable.
        // `UNNotificationResponse` is sealed (no public initialiser),
        // so without this split the mapping cannot be exercised by
        // tests except through the indirect `formatWaitResponse`
        // path, which already receives the *mapped* value — leaving
        // the mapping itself untested.
        return printableActionID(actionIdentifier: response.actionIdentifier)
    }

    /// String-taking sibling of `printableActionID(from:)`. Takes the
    /// raw `actionIdentifier` value (the same string
    /// `UNNotificationResponse.actionIdentifier` would return) so
    /// tests can drive the mapping without constructing a sealed
    /// `UNNotificationResponse`.
    ///
    /// Production callers prefer `printableActionID(from:)` for
    /// type-safety with `UNNotificationResponse`; this overload
    /// exists solely as a test seam.
    ///
    /// - Parameter actionIdentifier: The raw action identifier
    ///   string. Apple's default/dismiss reverse-DNS constants are
    ///   collapsed to short sentinels; any other value passes
    ///   through verbatim.
    /// - Returns: The user-facing label to print on stdout.
    static func printableActionID(actionIdentifier: String) -> String {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            return waitDefaultSentinel
        case UNNotificationDismissActionIdentifier:
            return waitDismissSentinel
        default:
            return actionIdentifier
        }
    }

    /// Extract the user-typed text from a `UNTextInputNotificationResponse`,
    /// or `nil` for a plain `UNNotificationResponse`. The `--wait` printer
    /// emits this on the line after the action id when present.
    ///
    /// Returns the text verbatim — the user-typed value can contain
    /// arbitrary characters (newlines, NUL bytes, multi-byte UTF-8).
    /// Receivers should read the remaining bytes after the action-id
    /// line until EOF rather than line-by-line, otherwise embedded
    /// newlines truncate.
    ///
    /// `nonisolated static` so tests can pin the extraction without
    /// constructing a real notification center response.
    static func textInputResponseText(
        from response: UNNotificationResponse
    ) -> String? {
        guard let textResponse = response as? UNTextInputNotificationResponse else {
            return nil
        }
        return textResponse.userText
    }
}
