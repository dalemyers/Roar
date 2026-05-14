import AppKit

// Known limitation: notifications posted from a terminal-launched
// `roar` show Terminal's icon, not Roar's. The cause is macOS's
// `responsible_pid` attribution — `usernoted` reads the kernel
// flag (not `Bundle.main.bundleIdentifier`) to decide the icon,
// and a binary `exec`'d from Terminal inherits Terminal's pid in
// that slot. v0.1.6 attempted a fix via the private
// `responsibility_spawnattrs_setdisclaim` API with a
// `POSIX_SPAWN_SETEXEC` re-exec, but the combination of hardened
// runtime + signed bundle + disclaim re-exec hangs AppKit's
// startup in the disclaimed image (sampled process can't be
// introspected without `get-task-allow=true`, which would defeat
// the rest of the project's security model). Reverted in v0.1.7;
// a future child-spawn variant (parent forwards stdio + signals,
// disclaimed child does the work) may be tried later.

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
