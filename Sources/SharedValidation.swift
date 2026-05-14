import ArgumentParser
import Foundation

/// Shared validation helpers used by multiple subcommands.
///
/// The "trim, reject empty, optionally reject control characters" shape
/// is duplicated across `Send`'s many `validateFooID` / `parseFoo`
/// helpers and `Dismiss.validateIdentifiers`. Centralising the rule
/// here keeps the wording (and the failure modes it screens for)
/// consistent at every flag site, and gives tests a single seam to
/// pin the contract.
///
/// The helpers are `nonisolated static` so they can be called from
/// any actor context and from tests directly.
enum SharedValidation {

    /// Reject empty / whitespace-only input, and (optionally) input
    /// containing control characters. Returns the trimmed value so
    /// callers that need the canonicalised form (e.g. before further
    /// parsing) can reuse it without a second `trimmingCharacters` call.
    ///
    /// Passing `nil` is the "flag absent" case — the helper short-
    /// circuits with `nil` so callers can write
    /// `let trimmed = try SharedValidation.requireNonBlank(opt, flag: "--foo")`
    /// and pattern-match on the optional result.
    ///
    /// The control-character screen is opt-in because some flags
    /// (e.g. `--body`, `--repeat`) legitimately accept whitespace
    /// characters that fall inside `CharacterSet.controlCharacters`
    /// (tabs, newlines), and others (e.g. `--identifier`,
    /// `--thread-id`) bridge to C-string XPC payloads where a NUL
    /// truncates downstream consumers.
    ///
    /// The check ordering is intentional and load-bearing:
    ///   1. `nil` short-circuit (flag not passed).
    ///   2. Trim and reject empty / whitespace-only result.
    ///   3. (Optional) control-character screen on the ORIGINAL value
    ///      — surrounding whitespace was already accepted by trim,
    ///      so screening the trimmed value would let `" name "`
    ///      pass (spaces are not in `controlCharacters`) while
    ///      `"name\t"` would fail; we want the same diagnostic
    ///      regardless of position.
    /// Length and call-site-specific checks live at the consumer
    /// (e.g. `validateRequestIdentifier`'s `maximumIdentifierLength`
    /// cap) — this is intentional: every validator layers its own
    /// caps on top of the trim+control-char baseline pinned here.
    ///
    /// The return value is intentionally NOT `@discardableResult`:
    /// every call site is required to bind the trimmed value and
    /// thread it downstream. Discarding it produced a class of bug
    /// where `--thread-id ' foo '` would validate as non-empty but
    /// `content.threadIdentifier = threadID` reads the un-trimmed
    /// property — silently writing `" foo "` into the XPC payload.
    /// Sites that genuinely don't need the trimmed value (e.g.
    /// `Dismiss.validateIdentifiers` which iterates already-known
    /// strings) bind to `_` explicitly so the intent is visible.
    ///
    /// - Parameters:
    ///   - value: The user-supplied flag value, or `nil` if the flag
    ///     was not passed.
    ///   - flag: User-facing label used in the error message (e.g.
    ///     `"--identifier"` or `"Notification identifiers"`). The
    ///     message reads `"\(flag) cannot be empty..."`, so this
    ///     string must form a grammatical subject in that template.
    ///   - emptyAdvice: Optional sentence appended to the empty /
    ///     whitespace-only error. Use it to point the user at a
    ///     valid example (e.g. `"Provide a bundle identifier
    ///     (e.g. com.apple.Safari), or omit the flag entirely."`).
    ///     Pass `""` to use the bare template.
    ///   - rejectControlCharacters: When `true`, also rejects any
    ///     value containing a `CharacterSet.controlCharacters`
    ///     character (NUL, newlines, tabs, ESC, etc.). Defaults to
    ///     `false` for flags whose payload naturally includes
    ///     whitespace control chars (body text, multi-line config).
    ///   - controlCharactersAdvice: Optional sentence appended to the
    ///     control-character error. Defaults to a generic
    ///     "printable ASCII" pointer; sites with a more specific
    ///     hazard (e.g. attachment paths feeding `lstat`) can
    ///     override.
    /// - Returns: The trimmed value, or `nil` if `value` was `nil`.
    /// - Throws: `ValidationError` on empty/whitespace-only input, or
    ///   (when `rejectControlCharacters` is `true`) on control
    ///   characters.
    nonisolated static func requireNonBlank(
        _ value: String?,
        flag: String,
        emptyAdvice: String = "",
        rejectControlCharacters: Bool = false,
        controlCharactersAdvice: String =
            "Stick to printable ASCII for portability."
    ) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Build the message in two pieces so the trailing space
            // between the template and the advice is only present when
            // the caller actually supplied advice.
            var message = "\(flag) cannot be empty or whitespace-only."
            if !emptyAdvice.isEmpty {
                message += " \(emptyAdvice)"
            }
            throw ValidationError(message)
        }
        if rejectControlCharacters,
           value.rangeOfCharacter(from: .controlCharacters) != nil {
            var message =
                "\(flag) cannot contain control characters "
                + "(NUL, newlines, tabs, etc.)."
            if !controlCharactersAdvice.isEmpty {
                message += " \(controlCharactersAdvice)"
            }
            throw ValidationError(message)
        }
        return trimmed
    }
}
