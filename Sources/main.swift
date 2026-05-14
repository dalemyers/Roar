import AppKit

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
