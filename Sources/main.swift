import AppKit
import Darwin
import Foundation

// Disclaim Terminal's UI-responsibility chain so `usernoted` posts
// notifications under our bundle's icon, not Terminal's.
//
// Background. When `roar` is exec'd from Terminal (the common
// install path: `/opt/homebrew/bin/roar` symlinked to the binary
// inside `/Applications/Roar.app/Contents/MacOS/roar`), the kernel
// inherits the *responsible_pid* attribute from Terminal. UN's
// `usernoted` daemon ignores `Bundle.main.bundleIdentifier` for
// the icon lookup and instead asks the kernel "who is responsible
// for this delivery?" — gets Terminal's pid back — and renders
// Terminal's icon on the banner, even though everything else
// about the notification (auth grant, click handler attribution,
// etc.) is correctly scoped to `io.myers.roar`.
//
// Apple's pre-Sequoia private API `responsibility_disclaim(pid)`
// flipped this flag in place. It was removed from libsystem in
// later macOS releases — `dlsym` returns NULL for it on macOS 26
// — leaving only `responsibility_spawnattrs_setdisclaim`, which
// disclaims the *child* of a `posix_spawn` rather than the
// caller. So the modern pattern is: re-exec ourselves with the
// disclaim attribute set, replacing the current process image.
// The re-exec'd copy is its own responsible process; usernoted's
// later lookup resolves to `io.myers.roar` and our icon renders.
//
// Sparkle and a handful of recent homebrew CLIs ship this pattern.
// Apple's notary service does not audit imported symbols for
// private-API usage (it gates on signatures, hardened runtime, and
// secure timestamps — not symbol whitelists), so the disclaim
// re-exec survives notarisation.
//
// Resilience:
//  - The disclaim symbol is resolved at runtime via `dlsym`. If
//    Apple removes it in a future macOS, we silently fall
//    through to the old behaviour (Terminal icon, otherwise
//    functional) rather than crashing at startup.
//  - An env-var marker (`ROAR_RESPONSIBILITY_DISCLAIMED=1`) is
//    set before the re-exec and checked at the top of this
//    function so the disclaimed copy doesn't recurse.
//  - `posix_spawn` failures (rare; would indicate ENOMEM or
//    cosmic-ray-level kernel issues) also fall through.
//  - XCTest is skipped — the test host is the same binary, and
//    re-execing under XCTest would discard the runner's state.
private func reExecWithResponsibilityDisclaim() {
    let envMarker = "ROAR_RESPONSIBILITY_DISCLAIMED"
    let env = ProcessInfo.processInfo.environment
    if env[envMarker] != nil { return }
    if env["XCTestConfigurationFilePath"] != nil { return }

    // Look up the private spawnattrs API at runtime. RTLD_DEFAULT
    // (-2 on Darwin) searches every loaded library.
    typealias SetDisclaimFn =
        @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    guard let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2),
          let sym = dlsym(rtldDefault, "responsibility_spawnattrs_setdisclaim")
    else { return }
    let setDisclaim = unsafeBitCast(sym, to: SetDisclaimFn.self)

    // Resolve our own executable path. `_NSGetExecutablePath`
    // returns the real on-disk path even when the binary was
    // invoked via a symlink — exactly what we need for the
    // posix_spawn.
    var exePath = [CChar](repeating: 0, count: Int(PATH_MAX))
    var exePathLen = UInt32(exePath.count)
    guard _NSGetExecutablePath(&exePath, &exePathLen) == 0 else { return }

    // Build the spawn attributes: SETEXEC replaces the current
    // process image instead of forking + executing in a child,
    // and the disclaim flag promotes the new image to its own
    // responsible_pid. We deliberately ignore the setDisclaim
    // return value — a failure there means the kernel rejected
    // the attribute, in which case we'd rather still re-exec
    // (and accept the wrong icon) than fail the whole CLI start.
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC))
    _ = setDisclaim(&attr, 1)

    // Set the marker BEFORE the spawn so the re-exec'd image
    // sees it and skips the disclaim path on its own startup.
    // The marker lives only in this process's environment; the
    // calling shell never sees it because posix_spawn passes the
    // (modified) current environ to the new image.
    setenv(envMarker, "1", 1)

    // Re-exec with the original argv intact. The duplicated C
    // strings leak if the spawn succeeds (the new image takes
    // over before we can free them) and the strdup allocations
    // are reclaimed on the eventual process exit anyway. The
    // explicit `free` on the failure path keeps Valgrind / leak
    // sanitisers happy if anyone runs them.
    let cArgs: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
    var cArgv = cArgs + [nil]

    var ignoredPid: pid_t = 0
    let spawnResult: Int32 = exePath.withUnsafeBufferPointer { exeBuf in
        cArgv.withUnsafeMutableBufferPointer { argvBuf in
            posix_spawn(
                &ignoredPid,
                exeBuf.baseAddress,
                nil,
                &attr,
                argvBuf.baseAddress,
                nil   // inherit current environ (which now carries the marker)
            )
        }
    }

    // Only reached on spawn failure. Clean up the strdups and
    // the env marker (so an unrelated retry in the same process
    // doesn't observe a stale flag) and let the caller proceed
    // without disclaim. The CLI still works; the icon stays
    // wrong.
    _ = spawnResult
    for ptr in cArgs { free(ptr) }
    unsetenv(envMarker)
}

reExecWithResponsibilityDisclaim()

// Entry point. We can't use @main because AsyncParsableCommand and
// NSApplication both want to own process startup. Instead, install our
// NSApplicationDelegate, run the AppKit runloop, and let the delegate
// dispatch into ArgumentParser once launch finishes.
//
// `MainActor.assumeIsolated` is safe at program start: the entry point
// is guaranteed to be on the main thread before any concurrency
// machinery starts, so asserting main-actor isolation can construct the
// `@MainActor` delegate and configure `NSApplication.shared`.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = RoarAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
