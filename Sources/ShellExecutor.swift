import Darwin
import Foundation
import os

/// Shell-on-click subsystem. Owns the `posix_spawn` plumbing, the
/// scrubbed-env builder, the wall-clock watchdog with the reap-vs-kill
/// interlock, the click-time command validator, and the unified-log
/// handle that surfaces `--exec` lifecycle to `log show`.
///
/// Extracted out of `RoarAppDelegate` because none of these need the
/// `@MainActor` isolation or per-instance state the delegate carries —
/// the watchdog body runs in a `Task.detached`, every helper is
/// `static` / `nonisolated`, and the only piece of mutable state
/// (`OSAllocatedUnfairLock<Bool>` for the reap interlock) is created
/// per invocation and shared between the main task and the watchdog
/// inside the same `runShell` call.
///
/// Modelled as `enum`-as-namespace, mirroring `URLValidation` and
/// `SharedValidation`: the executor is a collection of pure
/// functions, not a stateful service. Dependency direction is
/// strictly delegate → executor; `RoarAppDelegate` passes its
/// debug-stderr helpers in as closures rather than the executor
/// reaching back into the delegate.
enum ShellExecutor {

    /// Unified-log handle for shell-exec lifecycle messages. Subsystem
    /// matches the bundle id so a user investigating
    /// `--exec`-launched commands can filter via
    /// `log show --predicate 'subsystem == "io.myers.roar"'`.
    /// `category: "exec"` further narrows the filter to shell-exec
    /// records, separate from any future log emissions in the
    /// delegate. `nonisolated` so the `Task.detached` body in
    /// `runShell` can read it without an actor hop.
    nonisolated static let execLog = Logger(
        subsystem: "io.myers.roar", category: "exec")

    /// Wall-clock cap for `--exec` shell commands. A misbehaving
    /// command (`sleep 600`, a `read` waiting on closed stdin, …) would
    /// otherwise hold the click handler indefinitely. On timeout we
    /// SIGTERM, give a grace window, then SIGKILL.
    ///
    /// 60 seconds is intentionally generous — typical `--exec`
    /// invocations finish in milliseconds, but real use cases include
    /// `make`-style build wrappers, short scripts that run a
    /// network round-trip, and editor-launching commands that take a
    /// moment to settle. Lowering the cap would silently SIGKILL
    /// those, surprising the user. The cost of a high cap is that a
    /// runaway command holds the click handler for up to a minute;
    /// the user can see it via
    /// `log show --predicate 'process == "roar"' --last 5m`
    /// (see `execLog` above) and kill it manually if needed.
    static let shellCommandTimeout: Duration = .seconds(60)

    /// Grace period between SIGTERM and SIGKILL in `runShell`. Most
    /// well-behaved processes exit cleanly on SIGTERM within this
    /// window; anything still running is force-killed.
    static let shellSignalGrace: Duration = .seconds(2)

    /// Whether a `roar.exec.command` value pulled from a notification's
    /// `userInfo` is safe to hand to the shell-exec path. Currently
    /// the only check is rejection of embedded NUL bytes: `posix_spawn`
    /// builds argv with `strdup`, which truncates Swift strings at
    /// the first NUL — so a notification posted by any same-bundle-id
    /// process with `roar.exec.command = "echo ok\0; rm -rf $HOME"` would
    /// silently run a different command than what the debug log /
    /// userInfo inspection shows.
    ///
    /// The send-time validator (`Send.validateExecOptIn`) already
    /// rejects NUL in `--exec`. This click-time check is the
    /// security boundary against userInfo spoofed by any other
    /// process posting under the same bundle id; nonisolated `static`
    /// so tests can exercise the policy without spinning up the
    /// `@MainActor`-isolated `handleActivation` path.
    static func isClickCommandSafe(_ command: String) -> Bool {
        !command.contains("\0")
    }

    /// Run the given shell command via `/bin/sh -c` on a background
    /// thread, awaiting completion.
    ///
    /// `Foundation.Process` does not expose a way to put the child in
    /// its own process group, which means `kill(pid, ...)` from the
    /// watchdog only targets `/bin/sh` itself — any subprocesses the
    /// shell spawned (`sleep 600`, double-forks, anything backgrounded)
    /// keep running and defeat the timeout. We use `posix_spawn`
    /// directly with `POSIX_SPAWN_SETPGROUP` (and pgid=0, asking the
    /// kernel to make the child its own group leader) so the watchdog
    /// can signal the whole group via `kill(-pgid, ...)`.
    ///
    /// `/bin/sh`'s stdout and stderr are redirected to `/dev/null`. The
    /// previous implementation captured them through a pipe for `ROAR_DEBUG`
    /// logging, but a backgrounded grandchild (`cmd & disown`, `setsid …`)
    /// inherits the dup'd pipe fd and keeps the write end open after the
    /// shell exits, which made `readDataToEndOfFile` block indefinitely
    /// and `waitpid` was never reached. Callers that want output
    /// captured can do it inside their own `--exec` command
    /// (`cmd > /tmp/log 2>&1`).
    ///
    /// A watchdog Task enforces `shellCommandTimeout`. On expiry it
    /// signals `kill(-pgid, SIGTERM)`, waits `shellSignalGrace`, then
    /// `kill(-pgid, SIGKILL)`. Group-targeted signals catch the
    /// shell's descendants too — except for any that called `setsid` to
    /// leave the group, which the timeout cannot reach by design.
    ///
    /// - Parameters:
    ///   - command: A shell command suitable for `/bin/sh -c`.
    ///   - debugStderr: Caller-supplied env-gated stderr writer used
    ///     for the timeout/waitpid diagnostics. Injected rather than
    ///     looked up on `RoarAppDelegate` so this module has a clean
    ///     one-way dependency on the delegate (delegate → executor).
    ///   - debugOrBriefStderr: Caller-supplied dual-mode stderr writer
    ///     (verbose under `ROAR_DEBUG`, brief otherwise). Used for
    ///     the spawn-failure diagnostic whose detail may carry user
    ///     content.
    /// - Returns: `true` if the command exited with status 0. A
    ///   watchdog kill counts as failure.
    static func runShell(
        command: String,
        debugStderr: @escaping @Sendable (String) -> Void,
        debugOrBriefStderr: @escaping @Sendable (_ detail: String, _ brief: String) -> Void
    ) async -> Bool {
        let timeout = shellCommandTimeout
        let grace = shellSignalGrace
        // Announce the launch through the unified log so a user
        // investigating a long-running `--exec` can find what's
        // executing without needing `ROAR_DEBUG` set ahead of time.
        // `.default` log level is visible to the user via
        // `log show --predicate 'process == "roar"'` without
        // elevated privileges. The command is marked `public` because
        // the user typed it themselves at send-time and the click
        // confirmed they want it to run; obscuring it here would just
        // make debugging harder. The wall-clock cap is included so a
        // reader of the log can correlate timing without cross-
        // referencing the source.
        execLog.log(
            level: .default,
            "Running --exec shell command (timeout \(timeout, privacy: .public)): \(command, privacy: .public)"
        )
        return await Task.detached(priority: .userInitiated) {
            let pid: pid_t
            do {
                pid = try spawnShell(command: command)
            } catch {
                debugOrBriefStderr(
                    "Failed to launch shell command: \(error.localizedDescription)\n",
                    "Shell command failed to launch (set ROAR_DEBUG for details).\n"
                )
                return false
            }
            // Reap-vs-kill interlock: `Task.sleep` returning naturally
            // races the post-`waitpid` `cancel()` — the cancellation
            // signal isn't synchronous across Tasks, so the watchdog
            // can wake from `sleep`, observe `Task.isCancelled == false`,
            // and call `kill(-pid, SIGTERM)` *after* the main task
            // already reaped the child. The kernel may have recycled
            // that pgid by then, which would deliver SIGTERM/SIGKILL to
            // an unrelated process group of the same user.
            //
            // `OSAllocatedUnfairLock<Bool>` closes the window: the main
            // task sets `reaped = true` under the lock *before*
            // calling `watchdog.cancel()`, and the watchdog re-checks
            // the flag under the same lock immediately before each
            // signal call. Either ordering — main-task-wins or
            // watchdog-wins — is now safe: if the watchdog sees the
            // flag set, it skips the signal; if the main task hasn't
            // set it yet, the signal lands on the live pgid before the
            // kernel can recycle.
            let reapedFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
            let watchdog = Task<Bool, Never> {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Cancelled by the post-waitpid cancel below —
                    // command finished cleanly before the timeout.
                    return false
                }
                // Signal the whole process group (negative pid).
                // ESRCH (no such process) is expected if the child
                // exited between the sleep and here.
                guard killIfNotReaped(pid: pid, signal: SIGTERM, reapedFlag: reapedFlag) else {
                    return false
                }
                do {
                    try await Task.sleep(for: grace)
                } catch {
                    // Cancelled during the grace window because
                    // `waitpid` already reaped the child — SIGTERM was
                    // enough. The flag is already set by the main
                    // task, so a redundant `killIfNotReaped` call
                    // would also be a no-op, but returning early skips
                    // the syscall.
                    return true
                }
                _ = killIfNotReaped(pid: pid, signal: SIGKILL, reapedFlag: reapedFlag)
                return true
            }

            var status: Int32 = 0
            var reaped = false
            // `errno` is per-thread but every syscall the runtime makes
            // after `waitpid` (Task cancellation, the actor hop into
            // `await watchdog.value`, the stderr `write` for the
            // timeout diagnostic) can overwrite it. Capture it here, on
            // the same line as the failing call, so the post-loop
            // diagnostic reports the actual waitpid failure rather than
            // whatever the most recent unrelated syscall left behind.
            var waitpidErrno: Int32 = 0
            // Loop in case waitpid is interrupted by a signal (EINTR).
            // _W_INT-style bit layout: low 7 bits = signal/exit-mode,
            // high 8 bits of low 16 = exit status. Any errno other than
            // EINTR is a real failure (ECHILD, EINVAL, …) — treat it as
            // a failed run rather than mistakenly reading status==0 as
            // a clean exit, which is the default-initialised value.
            while true {
                let rc = waitpid(pid, &status, 0)
                if rc == pid { reaped = true; break }
                if rc == -1, errno == EINTR { continue }
                waitpidErrno = errno
                break
            }
            // Set the interlock flag *before* cancelling the watchdog,
            // so a watchdog that's mid-flight between its `sleep`
            // returning and its `killIfNotReaped` call sees the flag
            // set and skips the syscall. Cancellation is asynchronous;
            // the lock is synchronous.
            reapedFlag.withLock { $0 = true }
            watchdog.cancel()
            let timedOut = await watchdog.value
            if timedOut {
                debugStderr(
                    "Shell command exceeded \(timeout) and was killed.\n")
            }
            if !reaped {
                debugStderr(
                    "waitpid failed for shell command (errno \(waitpidErrno)).\n")
            }
            let exitedCleanly = reaped
                && (status & 0x7f) == 0
                && ((status >> 8) & 0xff) == 0
            return !timedOut && exitedCleanly
        }.value
    }

    /// Reap-vs-kill interlock primitive: send `signal` to `-pid`
    /// (the whole process group) iff `reapedFlag` is still false
    /// under the lock. Used by the `runShell` watchdog to skip the
    /// SIGTERM/SIGKILL when the main task has already reaped the
    /// child — without this gate, the kernel may have recycled the
    /// pgid to an unrelated process group of the same user, and the
    /// signal would land on it.
    ///
    /// The lock is read-modify-acquired: the watchdog reads the
    /// flag and (if false) emits the syscall *under* the lock, so a
    /// concurrent `reapedFlag.withLock { $0 = true }` from the main
    /// task either runs before the read (the signal is skipped) or
    /// after the syscall returns (the signal landed on the still-live
    /// pgid before the kernel could recycle it). Either ordering is
    /// safe; the unsafe ordering — write between the read and the
    /// syscall — is excluded by holding the lock across both.
    ///
    /// `static` (and non-isolated by virtue of being on an enum
    /// namespace) so the `Task.detached` watchdog body can call it
    /// without an actor hop. Tests pin the policy directly.
    ///
    /// - Parameters:
    ///   - pid: The process id of the shell child. Signalled via its
    ///     negation so the kill targets the whole pgid.
    ///   - signal: SIGTERM on the first watchdog tick, SIGKILL on the
    ///     post-grace tick.
    ///   - reapedFlag: Shared interlock. Main task flips this to
    ///     `true` after `waitpid` returns and before cancelling the
    ///     watchdog.
    /// - Returns: `true` if the signal was sent (flag was false),
    ///   `false` if the signal was skipped because the flag was
    ///   already set. The boolean lets the watchdog short-circuit
    ///   the SIGKILL phase when the SIGTERM phase already saw the
    ///   reap.
    @discardableResult
    static func killIfNotReaped(
        pid: pid_t,
        signal: Int32,
        reapedFlag: OSAllocatedUnfairLock<Bool>
    ) -> Bool {
        return reapedFlag.withLock { flag in
            if flag { return false }
            _ = kill(-pid, signal)
            return true
        }
    }

    /// Construct the environment passed to the `/bin/sh -c` child.
    /// Replaces the previous `ProcessInfo.processInfo.environment`
    /// passthrough, which was unsafe in the click-handler context.
    ///
    /// A hostile parent shell (or any user process that controls
    /// `roar`'s env between send and click) can set:
    ///
    ///   * `PATH=~/.attacker-bin:$PATH` — bare-name commands in
    ///     `--exec` resolve to attacker binaries.
    ///   * `BASH_ENV` / `ENV` — `/bin/sh` reads these at startup
    ///     and sources whatever they name, before our command runs.
    ///   * `IFS` — changes how the shell splits words, defeating
    ///     simple defences around `--exec` content.
    ///   * `CDPATH` — silently rewrites `cd <name>` resolution.
    ///   * `LD_LIBRARY_PATH` / `DYLD_*` — would normally affect
    ///     dynamic linking; macOS's hardened runtime + SIP scrub most
    ///     of these for system binaries, but `/bin/sh` is not always
    ///     protected and not all configurations apply the scrub. Drop
    ///     them outright rather than relying on the OS.
    ///   * `SHELLOPTS` / `BASHOPTS` — set shell options before our
    ///     command parses.
    ///
    /// PATH is pinned to the system default — the same value launchd
    /// cold-launches every bundle with. Users who need Homebrew or a
    /// custom PATH can set it inside their `--exec` value
    /// (`PATH=/opt/homebrew/bin:$PATH brew foo`).
    ///
    /// HOME, USER, LOGNAME, LANG, LC_*, TZ, TMPDIR are passed through
    /// because common commands rely on them and they don't influence
    /// command resolution. They are NOT a security boundary — a
    /// hostile parent can still set weird values — but they let
    /// `--exec` shell commands behave the way users expect on a
    /// non-hostile box.
    ///
    /// `static` so `spawnShell` can call it from its
    /// `Task.detached` context, and so tests can pin the rules
    /// without spinning up a real subprocess.
    ///
    /// - Parameter parentEnv: The environment to filter. In production
    ///   this is `ProcessInfo.processInfo.environment`; tests pass
    ///   their own fixtures.
    /// - Returns: An array of `KEY=VALUE` strings ready to hand to
    ///   `posix_spawn` after `strdup`-ing each.
    static func buildSpawnEnvironment(parentEnv: [String: String]) -> [String] {
        var pinned: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        // Locale-related keys: the full LC_* family per POSIX, not
        // just LC_ALL / LC_CTYPE. Users expecting LC_MONETARY to
        // shape currency formatting in a `--exec` command would
        // otherwise see surprising "default locale" behaviour.
        let inheritedKeys = [
            "HOME", "USER", "LOGNAME",
            "LANG", "LANGUAGE",
            "LC_ALL", "LC_COLLATE", "LC_CTYPE", "LC_MESSAGES",
            "LC_MONETARY", "LC_NUMERIC", "LC_TIME",
            "TZ", "TMPDIR",
        ]
        for key in inheritedKeys {
            guard let value = parentEnv[key] else { continue }
            // Defence in depth on the inherited value. We pin the
            // PATH (the main attack surface), but a hostile parent
            // could still set HOME / TMPDIR / TZ to a value
            // containing `=` or NUL that would land in the spawned
            // env as a malformed entry. `posix_spawn` walks the envp
            // array as NUL-terminated KEY=VALUE strings and the
            // child's `env`/`getenv` parser splits on the FIRST `=`,
            // so a value like `HOME=/tmp=/x` would put `=/x` into
            // HOME and an attacker-controlled fragment into adjacent
            // memory parsing. Drop any value containing `=` or NUL
            // outright — the parent env is implicitly trusted but
            // the cost of this check is one comparison per key, and
            // a legitimate user never has `=` in HOME.
            if value.contains("\0") || value.contains("=") {
                continue
            }
            pinned[key] = value
        }
        return pinned.map { "\($0.key)=\($0.value)" }
    }

    /// `posix_spawn` a `/bin/sh -c <command>` process with stdin/stdout/
    /// stderr redirected to `/dev/null`, placed in its own process group
    /// so the caller can signal the whole group via `kill(-pid, ...)`.
    ///
    /// Output is intentionally not captured — a backgrounded grandchild
    /// that inherits a pipe write fd keeps that fd open after `/bin/sh`
    /// exits, and `readDataToEndOfFile` then blocks forever waiting for
    /// EOF. Redirecting to `/dev/null` removes the deadlock entirely
    /// and costs only the `ROAR_DEBUG` echo of the command's output.
    ///
    /// `static` on the enum namespace so it can be called from the
    /// `Task.detached` body in `runShell` — none of its state
    /// touches the main actor.
    static func spawnShell(command: String) throws -> pid_t {
        // Parent opens /dev/null. The fd is duped into the child's
        // stdin/stdout/stderr by posix_spawn_file_actions_adddup2 and
        // then closed in the child. The parent always closes its own
        // copy before returning.
        let devNull = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard devNull >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(devNull) }

        // posix_spawn_*_init / *_destroy / *_add* all return an error
        // code (not -1/errno). They're documented as effectively
        // non-failing in practice — the action and attribute structs
        // are allocated on demand and the only failure mode is ENOMEM
        // — but ignoring the result is unsafe: a failed `_init` leaves
        // the struct uninitialised, and calling `_destroy` on that is
        // undefined. Gate the `defer` on init success and surface any
        // non-zero return as a POSIXError so the caller sees the cause.
        func check(_ rc: Int32) throws {
            guard rc == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
            }
        }

        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_adddup2(&actions, devNull, STDIN_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, devNull, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, devNull, STDERR_FILENO))
        // Close the parent-side fd in the child once it has been duped
        // onto the standard descriptors.
        try check(posix_spawn_file_actions_addclose(&actions, devNull))

        var attr: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attr))
        defer { posix_spawnattr_destroy(&attr) }
        // `POSIX_SPAWN_SETPGROUP` + pgid 0 = child becomes its own
        // process-group leader. Required so the watchdog's `kill(-pid)`
        // reaches the shell's children and not our own pgrp.
        //
        // `POSIX_SPAWN_SETSIGMASK` + an empty mask: explicitly clear
        // the child's signal mask rather than letting it inherit the
        // parent's. Roar's parent context is an AppKit / Swift
        // runtime that may have masked signals during XPC dispatch
        // or unified-log writes; inheriting that mask leaks parent
        // state into the user's `--exec` command and could (e.g.)
        // make a shell unable to receive SIGINT from a controlling
        // tty the parent had masked. The shell-on-click child has
        // no shared signal contract with the parent — a clean,
        // empty mask is the only defensible default.
        //
        // `POSIX_SPAWN_SETSIGDEF` + a full sigset: restore the
        // SIG_DFL disposition for every signal in the child.
        // `posix_spawn` without this flag carries the parent's
        // installed signal handlers across the spawn boundary into
        // the child's pre-`exec` window, then `exec` resets them —
        // but any signal delivered during the spawn-to-exec gap
        // would dispatch through a parent-installed handler in the
        // child's address space, which is undefined behaviour. The
        // explicit SETSIGDEF closes that window.
        try check(posix_spawnattr_setflags(
            &attr,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        ))
        try check(posix_spawnattr_setpgroup(&attr, 0))
        // Empty signal mask: nothing is blocked in the child.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        try check(posix_spawnattr_setsigmask(&attr, &emptyMask))
        // Full signal set for SIGDEF: every signal is reset to
        // SIG_DFL. `sigfillset` populates the set with every signal
        // the host kernel knows about.
        var fullMask = sigset_t()
        sigfillset(&fullMask)
        try check(posix_spawnattr_setsigdefault(&attr, &fullMask))

        // posix_spawn's argv must be a NULL-terminated array of
        // mutable C strings. `strdup` allocates copies we own and free
        // below.
        //
        // The shell command is prefixed with a best-effort `cd "$HOME"`
        // so a user running `--exec 'cat ./build.log'` lands in
        // their home directory rather than launchd's "/" cwd. The
        // `${HOME:-/}` form falls back to "/" when HOME is unset, and
        // `2>/dev/null; ` swallows the cd's diagnostic if the
        // directory has been deleted — the user's command then runs
        // unconditionally. Using a shell-level prefix instead of
        // `posix_spawn_file_actions_addchdir_np` avoids the macOS-26
        // deprecation on the latter (the non-`_np` form requires
        // macOS 14+, but the deployment target is 13).
        let argv = [
            "/bin/sh",
            "-c",
            "cd \"${HOME:-/}\" 2>/dev/null; \(command)"
        ]
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer {
            for case let p? in cArgv { free(p) }
        }

        // Pinned envp: see `buildSpawnEnvironment(parentEnv:)` for the
        // full rationale. Inheriting the parent's environment verbatim
        // (the previous shape) is unsafe — it lets a hostile parent
        // shell influence command resolution via PATH, BASH_ENV, IFS,
        // LD_*, etc.
        let envStrings = buildSpawnEnvironment(
            parentEnv: ProcessInfo.processInfo.environment
        )
        var cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer {
            for case let p? in cEnv { free(p) }
        }

        var pid: pid_t = 0
        let rc = cArgv.withUnsafeMutableBufferPointer { argvBuf in
            cEnv.withUnsafeMutableBufferPointer { envBuf in
                posix_spawn(&pid, "/bin/sh", &actions, &attr,
                            argvBuf.baseAddress, envBuf.baseAddress)
            }
        }
        if rc != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
        }
        return pid
    }
}
