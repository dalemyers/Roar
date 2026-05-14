import Darwin
import Foundation

/// Shared exit discipline for every `roar` subcommand.
///
/// Three commands (`send`, `clear`, `dismiss`) and one fast-fail
/// path (`Send.ensureAuthorized`) previously each carried their
/// own `ExitPlan` struct, their own `nonisolated(unsafe) static var
/// exitHook`, and their own `performExit` helper — three byte-
/// identical copies plus a fourth path that called
/// `Darwin.exit(1)` directly and silently bypassed the test seam.
/// Two failure modes from that arrangement:
///
/// 1. Cross-file test leaks. Each test file's `tearDown` cleared
///    only its own command's hook. The XCTest bundle short-circuits
///    `applicationDidFinishLaunching` (see `RoarAppDelegate`) and
///    runs all tests in one process, so a hook installed by a
///    test in `WaitExitDrainTests` could (in theory) survive into
///    the next test file's setup if a test had thrown before its
///    `defer` registered.
///
/// 2. Test-seam bypass. `Send.ensureAuthorized` called
///    `Darwin.exit(1)` on permission denial — no hook consulted,
///    so the test suite never exercised that path. The first
///    review pass turned up "auth denial: zero coverage" as one
///    of the top findings.
///
/// Centralising both shapes into a single type fixes both: there
/// is exactly ONE hook to clear in `tearDown`, and the auth path
/// flows through it just like the success paths.
///
/// `enum` (uninstantiable) so callers always use the static API.
enum CommandExit {

    /// Description of an impending `Darwin.exit`. The fields
    /// capture everything the production code does between the
    /// last side effect and the actual `_exit` syscall: the drain
    /// duration the caller would sleep for, and the exit code
    /// itself.
    ///
    /// Sendable because the hook may run from arbitrary async
    /// contexts. Equatable so tests can pin the exact plan.
    struct Plan: Sendable, Equatable {
        let drain: Duration
        let code: Int32
    }

    /// Test seam: when non-`nil`, `perform(_:)` invokes this hook
    /// instead of sleeping + `Darwin.exit`. Production never sets
    /// it. The shape is async so the hook can suspend (e.g. signal
    /// a Task in the test that the plan was recorded) without
    /// forcing a detached Task at the call site.
    ///
    /// `nonisolated(unsafe)` because tests install / clear it from
    /// arbitrary contexts (async test methods, `defer` in
    /// synchronous test bodies, `tearDown` on the test class).
    /// `@Sendable` on the closure so the hook is safe to invoke
    /// from the `async` body of `perform`. Tests MUST clear via
    /// `defer` so a leak doesn't poison a subsequent test.
    nonisolated(unsafe) static var hook: (@Sendable (Plan) async -> Void)?

    /// Either invoke `hook` (test path) or sleep the drain and
    /// `Darwin.exit` (production path). All terminal call sites
    /// in `Send.run`, `Clear.run`, `Dismiss.run`, and
    /// `Send.ensureAuthorized` route through this single
    /// chokepoint — a future drain or exit-code change cannot
    /// accidentally bypass the hook.
    ///
    /// `Darwin.exit` does NOT return; in the production path this
    /// function therefore also does not return. In the test path
    /// it returns after the hook awaits, letting the test driver
    /// proceed without the process actually terminating.
    ///
    /// `nonisolated` because callers reach it from
    /// `AsyncParsableCommand.run()` contexts (no actor).
    nonisolated static func perform(_ plan: Plan) async {
        if let hook {
            await hook(plan)
            return
        }
        if plan.drain > .zero {
            try? await Task.sleep(for: plan.drain)
        }
        Darwin.exit(plan.code)
    }
}
