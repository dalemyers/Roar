import ArgumentParser
import Darwin
import Foundation

/// Locate the `.app` bundle containing the running executable,
/// resolving any symlinks first.
///
/// `Bundle.main` derives its path from `_NSGetExecutablePath`,
/// which returns the argv-style path the kernel was handed at
/// `execve` time. When the binary is invoked via a symlink — the
/// Homebrew install path puts a symlink at
/// `/opt/homebrew/bin/roar` pointing inside the .app —
/// `Bundle.main`'s bundle URL is the symlink's parent directory
/// (`/opt/homebrew/bin/`), NOT the .app. Reading Info.plist keys
/// from `Bundle.main.infoDictionary` then returns nil and the
/// version string degrades to "unknown (unknown)".
///
/// Fix: resolve the executable path's symlink chain, walk three
/// levels up (MacOS/ → Contents/ → Roar.app), and construct a
/// `Bundle` from that real path. Falls back to `Bundle.main` on
/// any failure — the worst case is the same "unknown (unknown)"
/// display we'd have without the fix.
///
/// The resolved path is computed once and cached at module load.
/// Successive calls reuse the same Bundle reference.
private let roarBundle: Bundle = {
    var pathBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
    var pathLen = UInt32(pathBuf.count)
    guard _NSGetExecutablePath(&pathBuf, &pathLen) == 0 else {
        return Bundle.main
    }
    let exeURL = URL(fileURLWithPath: String(cString: pathBuf))
        .resolvingSymlinksInPath()
    // Walk: MacOS/<binary> → Contents/MacOS → Contents → .app
    let appURL = exeURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    guard appURL.pathExtension == "app",
          let bundle = Bundle(url: appURL) else {
        return Bundle.main
    }
    return bundle
}()

/// Top-level `roar` command. Subcommands are wired here.
///
/// No `defaultSubcommand`: a bare `roar` invocation prints the
/// command-level help so first-run users discover the subcommand
/// list instead of being greeted by `Send`'s "provide --body"
/// error. Users who want the previous behaviour pass `roar send`
/// explicitly.
struct Roar: AsyncParsableCommand {
    static let configuration: CommandConfiguration = {
        // The version string is composed at runtime from the
        // bundle's Info.plist so the value always matches what
        // the release pipeline shipped — no risk of the Swift
        // literal drifting out of sync with the git tag,
        // GitHub Release name, or Homebrew cask version. The
        // Info.plist's fields are populated via `project.yml`'s
        // `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`
        // placeholders, which the release workflow overrides
        // from the git tag (`v0.1.7` → `0.1.7`) and the
        // workflow run number respectively. Local dev builds
        // inherit the `0.0.0` / `0` defaults declared in
        // `settings.base`.
        //
        // Format: `<marketing> (<build>)`, e.g. `0.1.7 (42)`.
        // A `"0"` build sentinel triggers the dev path: we
        // substitute a timestamp derived from the binary's
        // modification time so successive local rebuilds show
        // up as different "builds" without anyone having to
        // hand-bump a counter. The timestamp is sortable
        // (`yyyyMMddHHmm`) so `roar --version` output across
        // local builds remains comparable. Dev output looks
        // like `0.0.0 (202605142230)`, immediately visually
        // distinct from a CI release.
        let info = roarBundle.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let rawBuild = info?["CFBundleVersion"] as? String ?? "unknown"
        let buildLabel: String = {
            // The dev sentinel from `project.yml`'s
            // `CURRENT_PROJECT_VERSION = "0"`. CI release builds
            // always override this, so a `"0"` at runtime
            // unambiguously means "this is a local dev build."
            guard rawBuild == "0" else { return rawBuild }
            // mtime of the executable. `attributesOfItem` reads
            // the same metadata `ls -l` shows; the binary's
            // mtime is set at link time, so this changes once
            // per build and stays stable across multiple
            // invocations of the same build. Use the
            // symlink-resolved executable from `roarBundle` so
            // the lookup doesn't get a stale Homebrew-symlink
            // mtime when invoked via `/opt/homebrew/bin/roar`.
            let exePath = roarBundle.executableURL?.path
            let attrs = exePath.flatMap {
                try? FileManager.default.attributesOfItem(atPath: $0)
            }
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
            let formatter = DateFormatter()
            // POSIX locale because the format tokens are
            // grammar, not natural language — under
            // `LANG=ar_SA.UTF-8` the default DateFormatter
            // would emit Arabic-Indic digits, breaking the
            // "looks like an integer" property.
            formatter.locale = Locale(identifier: "en_US_POSIX")
            // UTC so a developer in one timezone can compare
            // their local build to a colleague's without
            // timezone confusion.
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMddHHmm"
            return formatter.string(from: mtime)
        }()
        return CommandConfiguration(
            commandName: "roar",
            abstract: "Send macOS user notifications from the command line.",
            version: "\(marketing) (\(buildLabel))",
            subcommands: [Send.self, List.self, Dismiss.self, Clear.self, Settings.self]
        )
    }()
}
