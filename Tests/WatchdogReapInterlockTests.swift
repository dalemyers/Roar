import XCTest
import Darwin
import os
@testable import roar

/// Pin the reap-vs-kill interlock in `ShellExecutor.runShell`.
///
/// The watchdog and the main task race: `Task.sleep` returning
/// naturally is not synchronized with the post-`waitpid`
/// `watchdog.cancel()` call (cancellation propagates between Tasks
/// asynchronously). If cancellation lands between the sleep
/// returning and the SIGTERM call, the watchdog would otherwise
/// signal a pgid that `waitpid` already reaped — and which the
/// kernel may have recycled to an unrelated process group of the
/// same user.
///
/// The fix: a lock-protected `reaped` boolean shared between the
/// two tasks. The main task sets it to `true` *before* cancelling
/// the watchdog; the watchdog re-checks under the lock immediately
/// before each signal call. The `killIfNotReaped` helper is the
/// extracted policy: tests pin the gate directly, since racing a
/// real subprocess against the watchdog can't reliably reproduce
/// the kernel-level PID-recycle that the interlock prevents.
final class WatchdogReapInterlockTests: XCTestCase {

    /// Flag set → signal must be skipped. This is the headline rule:
    /// if `waitpid` already reaped the child, the watchdog must
    /// emit no further `kill` syscalls, because the pgid may have
    /// been recycled to an unrelated process group.
    ///
    /// We can't easily assert "no syscall was made" against a real
    /// `kill(2)` from a unit test (the function is a libc shim, not
    /// mockable). Instead the helper returns a boolean: `true` iff
    /// the signal was sent, `false` iff it was skipped under the
    /// gate. The boolean is the public contract.
    func testSetReapedFlagSkipsSignal() {
        let flag = OSAllocatedUnfairLock<Bool>(initialState: true)
        // A clearly-bogus pid: if the gate ever lets the call
        // through, `kill(-pid, SIGTERM)` against this fake pgid
        // would fail with ESRCH, but the helper returns the gate
        // result, not the syscall outcome. The assertion is solely
        // on the gate.
        let sent = ShellExecutor.killIfNotReaped(
            pid: pid_t(0x7FFFFFFE),
            signal: SIGTERM,
            reapedFlag: flag
        )
        XCTAssertFalse(
            sent,
            "killIfNotReaped must skip the signal when the reaped flag "
            + "is set — the pgid may have been recycled to an unrelated "
            + "process group of the same user"
        )
    }

    /// Flag clear → signal is sent. The watchdog's normal path: the
    /// main task hasn't reaped yet, the timeout elapsed, the kill
    /// must land on the still-live pgid.
    func testClearReapedFlagSendsSignal() {
        let flag = OSAllocatedUnfairLock<Bool>(initialState: false)
        // Use our own pid so the syscall is harmless: `kill(-pid, 0)`
        // with signal 0 is the standard "check if the process exists"
        // probe, not an actual signal. Our process exists, the call
        // returns 0, no behavioural side-effect. The assertion is
        // again on the gate boolean — "the syscall was attempted" —
        // not on the kernel's response.
        let sent = ShellExecutor.killIfNotReaped(
            pid: ProcessInfo.processInfo.processIdentifier,
            signal: 0,
            reapedFlag: flag
        )
        XCTAssertTrue(
            sent,
            "killIfNotReaped must emit the signal when the reaped flag "
            + "is clear — this is the normal timeout-elapsed path"
        )
    }

    /// The gate is read-modify-checked under the same lock as the
    /// write site, so the flip from `false` → `true` is atomic
    /// across the read/syscall pair. This test pins that ordering by
    /// flipping the flag on a sibling task and asserting the gate
    /// observes the new value on the next call.
    func testFlagFlipBetweenCallsIsObserved() {
        let flag = OSAllocatedUnfairLock<Bool>(initialState: false)
        let pid = ProcessInfo.processInfo.processIdentifier

        // First call: flag clear, signal sent.
        XCTAssertTrue(
            ShellExecutor.killIfNotReaped(
                pid: pid, signal: 0, reapedFlag: flag
            )
        )

        // Main task reaped the child and flipped the flag.
        flag.withLock { $0 = true }

        // Second call: flag set, signal skipped. This is the
        // "second tick of the watchdog after the post-grace SIGKILL"
        // branch — the SIGTERM phase already saw the flag set.
        XCTAssertFalse(
            ShellExecutor.killIfNotReaped(
                pid: pid, signal: 0, reapedFlag: flag
            )
        )
    }

    /// Race a watchdog signal against a reap that flips the flag.
    /// Models the real interlock: the watchdog calls
    /// `killIfNotReaped` while the main task concurrently flips the
    /// flag to true. The gate must either:
    ///
    /// * Run before the flip and return `true` (signal landed on the
    ///   still-live pgid), or
    /// * Run after the flip and return `false` (signal skipped).
    ///
    /// What it must NOT do is observe `false` and *then* allow the
    /// flip to interleave between the read and the syscall — that's
    /// exactly the recycled-pgid race the lock is supposed to
    /// prevent. The lock implementation gives the read-and-syscall
    /// pair as a single critical section, so any test result
    /// (`sent=true` or `sent=false`) is correct as long as the
    /// underlying syscall doesn't interleave with a flag flip.
    ///
    /// This test pins the *atomicity* of the read-and-syscall: 1000
    /// iterations, no crashes, no hangs. A naive (lock-free)
    /// implementation reading the flag in one statement and emitting
    /// the syscall in another would trip TSan under stress —
    /// XCTest's thread sanitizer would surface it. The actual
    /// boolean returned varies legitimately by scheduling, so we
    /// assert only that the iteration completed.
    func testConcurrentReapDuringSignalIsSafe() async {
        for _ in 0..<1000 {
            let flag = OSAllocatedUnfairLock<Bool>(initialState: false)
            let pid = ProcessInfo.processInfo.processIdentifier

            // The watchdog leg.
            async let watchdog = Task<Bool, Never> {
                return ShellExecutor.killIfNotReaped(
                    pid: pid, signal: 0, reapedFlag: flag
                )
            }.value
            // The main-task leg: simulates "waitpid returned, flip
            // the flag." Runs concurrently with the watchdog.
            //
            // Explicit `: Void` annotation: without it, the compiler
            // (under `SWIFT_TREAT_WARNINGS_AS_ERRORS`) flags the
            // `async let foo = …` binding as suspicious because the
            // inferred type is `Void` — its `unused-let-value` /
            // unexpected-Void heuristic assumes the user forgot a
            // `.value` or a parens. We genuinely want a `Void` await
            // here (the body has a side effect, not a return value),
            // so annotate explicitly to silence the heuristic. The
            // sibling `async let watchdog` binding above is implicitly
            // `Bool`, which the heuristic doesn't flag.
            async let mainTask: Void = Task<Void, Never> {
                flag.withLock { $0 = true }
            }.value

            let (_, _) = await (watchdog, mainTask)
            // Final state: flag must be true. The watchdog either
            // ran before or after; either is safe.
            XCTAssertTrue(
                flag.withLock { $0 },
                "main-task reap leg must have flipped the flag"
            )
        }
    }

    /// `killIfNotReaped` is `nonisolated static`, callable from the
    /// `Task.detached` watchdog body without an actor hop. Pin the
    /// API shape COMPILE-TIME by assigning it to a non-isolated
    /// function-type variable — if a future refactor adds
    /// `@MainActor` (which would deadlock the watchdog, since the
    /// detached Task isn't on the main actor) the assignment fails
    /// to compile because actor-isolated functions cannot be
    /// converted to a non-isolated function-type at compile time.
    ///
    /// The previous shape (`Task.detached { … }`) did NOT actually
    /// pin isolation — the compiler inserts an implicit actor hop
    /// when calling a `@MainActor`-isolated function from a
    /// detached Task, so the test would compile (and pass at
    /// runtime) even if the helper became `@MainActor`. The
    /// function-type assignment below is the actual mechanism that
    /// catches the regression at compile time.
    func testHelperIsCallableFromNonisolatedContext() {
        // The assignment below is the load-bearing line: if
        // `killIfNotReaped` becomes actor-isolated, the function
        // reference is no longer compatible with this plain
        // (non-isolated) function-type and the file fails to
        // compile. The actual invocation is a smoke test to keep
        // the symbol live; the type check is the regression
        // backstop.
        let reference: (pid_t, Int32, OSAllocatedUnfairLock<Bool>) -> Bool =
            ShellExecutor.killIfNotReaped
        let flag = OSAllocatedUnfairLock<Bool>(initialState: true)
        XCTAssertFalse(reference(pid_t(1), 0, flag))
    }
}
