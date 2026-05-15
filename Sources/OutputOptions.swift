import ArgumentParser
import Foundation

/// Shared output-mode flags. Every subcommand `@OptionGroup`'s this so
/// `--json` works identically across `send`, `list`, `dismiss`, `clear`,
/// and `settings`. Adding a new subcommand without this `@OptionGroup`
/// trips `OutputModeTests.testEverySubcommandHasJSONFlag`.
struct OutputOptions: ParsableArguments {
    /// `--json` — emit a single JSON value on stdout instead of the
    /// subcommand's default text format. Schema per subcommand is
    /// documented in `docs/REFERENCE.md` under "Output modes" and is
    /// treated as a stable scripting ABI: shapes can gain fields, but
    /// renames or removals are major-version breaks.
    @Flag(name: .long, help: "Emit output as JSON instead of text.")
    var json: Bool = false
}

/// Serialise an `Encodable` to a compact, single-line UTF-8 JSON
/// string with sorted keys — the format every subcommand's
/// `--json` path emits. Compact (not pretty-printed) so the
/// output composes with `jq`, line-oriented shell tools, and
/// log aggregators; sorted keys so the byte output is
/// deterministic and diffable.
///
/// Force-tries the encode: the inputs are all in-process
/// `Codable` value types under our control, so a runtime
/// encoding failure would be a programming error worth crashing
/// on rather than swallowing. Tests pin the exact emitted
/// bytes per shape; a future schema change that breaks encoding
/// would surface in CI.
///
/// `nonisolated` because callers reach it from
/// `AsyncParsableCommand.run()` contexts and from main-actor-
/// isolated `Send` paths; the function holds no shared state.
nonisolated func encodeJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    // `.sortedKeys` is the only option we set. `.prettyPrinted`
    // is deliberately omitted so the output stays single-line;
    // `.withoutEscapingSlashes` is omitted because the default
    // (slash-escaping) is what `jq -c` produces, which keeps
    // the output familiar.
    encoder.outputFormatting = [.sortedKeys]
    // swiftlint:disable:next force_try
    let data = try! encoder.encode(value)
    // `String(bytes:encoding:)` is the lint-preferred path. The
    // bytes coming out of `JSONEncoder` are guaranteed valid
    // UTF-8 by the encoder's contract, so `??` -> "" would only
    // trigger on a kernel-level data corruption between encode
    // and decode — a "this can't happen" path. Empty string is
    // a safer fallback than crashing the CLI; the caller will
    // see an empty `--json` emission rather than a SIGABRT.
    return String(bytes: data, encoding: .utf8) ?? ""
}
