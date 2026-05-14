import ArgumentParser
import Foundation

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
        let info = Bundle.main.infoDictionary
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
            // invocations of the same build.
            let exePath = Bundle.main.executableURL?.path
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
