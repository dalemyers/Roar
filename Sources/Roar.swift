import ArgumentParser

/// Top-level `roar` command. Subcommands are wired here.
///
/// No `defaultSubcommand`: a bare `roar` invocation prints the
/// command-level help so first-run users discover the subcommand
/// list instead of being greeted by `Send`'s "provide --body"
/// error. Users who want the previous behaviour pass `roar send`
/// explicitly.
struct Roar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "roar",
        abstract: "Send macOS user notifications from the command line.",
        version: "0.1.0",
        subcommands: [Send.self, List.self, Dismiss.self, Clear.self, Settings.self]
    )
}
