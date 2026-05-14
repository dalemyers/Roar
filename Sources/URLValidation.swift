import Foundation

/// Shared validation for user-supplied URL strings on `--open-url` and
/// similar options.
///
/// **Allow-list semantics.** Only schemes the caller explicitly passes
/// in `allowedSchemes` are accepted; everything else is rejected. The
/// validator does not maintain a hardcoded deny list (and historically
/// did, but that was inverted on review — every dangerous scheme is
/// dangerous only because someone might enable it, so the right
/// expressive model is "schemes are off by default and must be turned
/// on one at a time"). Plain `URL(string:)` accepts almost anything
/// (including schemeless garbage like `"lol"`), so this validator
/// requires an explicit scheme AND that the scheme appear in the
/// caller's allow-list.
///
/// **Threat-model note for callers.** With pure allow-list semantics,
/// the burden of refusing a script-bearing scheme (`javascript:`,
/// `vbscript:`, `data:`) or a fileystem / network-mount scheme
/// (`file:`, `afp:`, `smb:`, `ftp:`) lives at the caller's
/// allow-list, not here. `Send.run` builds the default allow-list as
/// `defaultOpenSchemes` (http / https / mailto) and unions it with any
/// `--allow-url-scheme` values the user explicitly typed. A user who
/// passes `--allow-url-scheme javascript` is explicitly consenting to
/// the click-to-script risk — same-process exec via a click is
/// inherently their decision since they could just type
/// `bash -c 'curl … | bash'` instead. The click handler then
/// re-validates against the exact same allow-list, serialised into
/// userInfo at send time, so a click can't widen what a send agreed
/// to. (Same-bundle-id spoofing of the userInfo allow-list is a
/// separate concern documented in the README; the threat model for an
/// ad-hoc-signed CLI cannot prevent it.)
enum URLValidation {

    /// Default allow-list for `--open-url`: schemes that have no
    /// LaunchServices-driven side effects when handed to
    /// `NSWorkspace.open`. http/https open the user's browser at a
    /// URL they typed; mailto pops a compose window. Every other
    /// scheme must be opted in via `--allow-url-scheme`.
    static let defaultOpenSchemes: Set<String> = ["http", "https", "mailto"]

    /// `roar.open.allowedSchemes` userInfo key separator. The send-time
    /// validation pins the exact set of schemes the user agreed to,
    /// serialises here, and the click-time re-validation reads it back.
    /// Comma is safe because URL schemes are RFC 3986 `scheme =
    /// ALPHA *(ALPHA / DIGIT / "+" / "-" / ".")` — no comma in any
    /// legitimate scheme.
    static let allowedSchemesSeparator: Character = ","

    /// Pattern a scheme name must match to be acceptable as
    /// `--allow-url-scheme` input. RFC 3986: `scheme = ALPHA
    /// *(ALPHA / DIGIT / "+" / "-" / ".")`. The strict regex prevents
    /// a user from passing nonsense (spaces, commas, NUL bytes) into
    /// the allow-list, which would then leak into the userInfo
    /// serialisation and confuse the click-time re-parse. Matches
    /// case-insensitively — the validator normalises to ASCII
    /// lowercase before storing.
    static let schemeNamePattern = /^[a-zA-Z][a-zA-Z0-9+\-.]*$/

    enum Error: LocalizedError, CustomStringConvertible {
        case empty
        case malformed(String)
        case missingScheme(String)
        case missingTarget(String)
        case disallowedScheme(scheme: String, allowed: Set<String>)
        case containsCredentials
        case invalidSchemeName(String)

        var description: String {
            switch self {
            case .empty:
                return "URL is empty."
            case .malformed(let raw):
                return "'\(raw)' is not a valid URL."
            case .missingScheme(let raw):
                return "'\(raw)' has no URL scheme (expected e.g. https://...)."
            case .missingTarget(let raw):
                return "'\(raw)' has no host or path. Did you mean e.g. https://example.com?"
            case .disallowedScheme(let scheme, let allowed):
                let list = allowed.sorted().joined(separator: ", ")
                return "URL scheme '\(scheme)' is not in the allow-list. Allowed schemes: \(list). Add it with --allow-url-scheme \(scheme) (be aware that some schemes — javascript, data, file, applescript, etc. — can carry executable or filesystem-side-effect content)."
            case .containsCredentials:
                // Deliberately does NOT echo the URL — the embedded
                // credentials would land in the error message, then in
                // terminal scrollback, shell history (with redirection),
                // CI logs, and crash reporters.
                return "URL contains embedded credentials (user:password@host). Strip them or pass them out-of-band; the credentials would otherwise be stored in the notification's payload and visible in error output."
            case .invalidSchemeName(let name):
                return "'\(name)' is not a syntactically valid URL scheme name. Schemes must match RFC 3986: a letter followed by letters, digits, '+', '-', or '.'."
            }
        }

        var errorDescription: String? { description }
    }

    /// Validate a user-supplied `--allow-url-scheme` value: enforce
    /// the RFC 3986 scheme syntax and normalise to ASCII lowercase.
    /// Throwing here means a malformed scheme name (`"java script"`,
    /// `"abc,def"`, `"\0x"`) is surfaced at ArgumentParser time
    /// rather than leaking into userInfo and silently mis-matching
    /// the click-time re-parse.
    ///
    /// - Parameter raw: The user-supplied scheme name.
    /// - Returns: The scheme name normalised to ASCII lowercase.
    /// - Throws: `Error.invalidSchemeName` if the name does not match
    ///   the RFC 3986 scheme grammar.
    static func validateSchemeName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? schemeNamePattern.wholeMatch(in: trimmed)) != nil else {
            throw Error.invalidSchemeName(raw)
        }
        return trimmed.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// Build the exact allow-list a single `--open-url` invocation
    /// will use. Unions the default web/email schemes with the
    /// user-supplied `--allow-url-scheme` values, validating each
    /// addition's syntax and lowercasing it for comparison.
    ///
    /// `nonisolated static` so tests can pin the merge rule directly.
    ///
    /// - Parameter additions: Raw scheme names from `--allow-url-scheme`.
    /// - Returns: The combined, lowercased allow-list.
    /// - Throws: `Error.invalidSchemeName` if any addition is malformed.
    static func buildAllowList(additions: [String]) throws -> Set<String> {
        var combined = defaultOpenSchemes
        for raw in additions {
            let normalised = try validateSchemeName(raw)
            combined.insert(normalised)
        }
        return combined
    }

    /// Serialise an allow-list to the userInfo string form
    /// (`,`-joined, ASCII-lowercased). The click-time handler reads
    /// this back via `deserializeAllowList` to rebuild the exact set
    /// the send-time validator agreed to.
    ///
    /// `nonisolated static` so the round-trip is unit-testable.
    static func serializeAllowList(_ schemes: Set<String>) -> String {
        schemes.sorted()
            .joined(separator: String(allowedSchemesSeparator))
    }

    /// Inverse of `serializeAllowList`. Returns `nil` if the stored
    /// value is malformed (e.g. a same-bundle-id spoofer wrote
    /// garbage into the userInfo key); callers should treat that as
    /// "no allow-list" and reject the click. Empty or whitespace-
    /// only entries are dropped — they would never have been written
    /// by the send-time code path.
    ///
    /// - Parameter raw: The userInfo string.
    /// - Returns: The reconstructed allow-list, or `nil` if any
    ///   component fails the scheme-name validator.
    static func deserializeAllowList(_ raw: String) -> Set<String>? {
        let parts = raw.split(separator: allowedSchemesSeparator,
                              omittingEmptySubsequences: true)
        var schemes: Set<String> = []
        for part in parts {
            let s = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            // Re-run the same syntax check the send-time path runs;
            // a garbled value (spoofed userInfo, future-build
            // serialiser drift) is dropped rather than letting an
            // unparseable string become a permissive allow-list.
            guard let normalised = try? validateSchemeName(s) else {
                return nil
            }
            schemes.insert(normalised)
        }
        return schemes
    }

    /// Parse and validate a user-supplied URL string against an
    /// allow-list of schemes.
    ///
    /// - Parameters:
    ///   - raw: The user-supplied string.
    ///   - allowedSchemes: The set of schemes the caller is willing
    ///     to accept. Send-time callers compute this via
    ///     `buildAllowList(additions:)`; click-time callers compute
    ///     it via `deserializeAllowList(_:)` from the userInfo blob
    ///     written at send time.
    /// - Returns: A `URL` with a non-empty, allow-listed scheme.
    /// - Throws: `URLValidation.Error` on empty input, syntactic
    ///   malformation, missing scheme, scheme not in the allow-list,
    ///   or embedded credentials.
    static func parse(
        _ raw: String,
        allowedSchemes: Set<String> = defaultOpenSchemes
    ) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.empty }
        guard let url = URL(string: trimmed) else { throw Error.malformed(raw) }
        // POSIX-locale lowercasing is load-bearing for the allow-list
        // comparison below. Default `String.lowercased()` is
        // locale-aware: under `LANG=tr_TR.UTF-8`, "HTTP".lowercased()
        // produces "http" but "FILE".lowercased() produces "fı̇le"
        // (with U+0307 COMBINING DOT ABOVE), which would not match
        // any allow-list entry stored in ASCII lowercase. URL schemes
        // are ASCII per RFC 3986 §3.1; pinning the locale to
        // `en_US_POSIX` collapses every Unicode-cased input to the
        // ASCII form the allow-list expects.
        guard let scheme = url.scheme?.lowercased(with: Locale(identifier: "en_US_POSIX")),
              !scheme.isEmpty else {
            throw Error.missingScheme(raw)
        }
        if !allowedSchemes.contains(scheme) {
            throw Error.disallowedScheme(scheme: scheme, allowed: allowedSchemes)
        }
        // `URL(string:)` accepts inputs like "https://" (scheme present
        // but no authority and no path) or "https:/" (single slash —
        // parses with path "/", which the trivial isEmpty check missed
        // and which silently no-ops at `NSWorkspace.open` time). Require
        // either a non-empty host or non-`/` content after the scheme
        // delimiter.
        //
        // We deliberately do NOT trust `url.path` here: Foundation's
        // `URL.path` returns different values across macOS versions
        // for schemes without a `//` authority. On macOS 15.5 SDK
        // (Xcode 16.4 CI runner) `URL("mailto:foo@bar.com").path`
        // returns `""`; on macOS 26+ it returns `"foo@bar.com"`. The
        // older behaviour would silently reject every `mailto:` URL.
        // String-level inspection of the raw input is the only
        // SDK-portable answer.
        let host = url.host ?? ""
        if host.isEmpty {
            // Find the scheme delimiter and look at what follows.
            // `trimmed` is `<scheme>:<rest>`; we want `<rest>` with
            // any leading `/` stripped (`/` and `//` are authority /
            // root-slash markers, not real target content).
            guard let colonIdx = trimmed.firstIndex(of: ":") else {
                throw Error.missingTarget(raw)
            }
            let afterScheme = trimmed[trimmed.index(after: colonIdx)...]
            let content = afterScheme.drop(while: { $0 == "/" })
            guard !content.isEmpty else {
                throw Error.missingTarget(raw)
            }
        }
        // Reject embedded user:password@ credentials. The URL is stored
        // verbatim in the notification userInfo (under `roar.open.url`)
        // and replayed at click time via NSWorkspace.open; any errors
        // mentioning the URL would leak the credentials to stderr /
        // terminal scrollback / CI logs.
        //
        // Mailto has no host so URLComponents.user is nil for
        // `mailto:foo@bar.com` (the @ is part of the path) — that case
        // is unaffected. For `http://user@host`, `.user` is "user" and
        // we reject.
        //
        // Empty-string userinfo (`https://@host/`) is treated as "no
        // credentials" rather than rejected — the `@` is technically
        // present but carries no secret. Some Foundation versions
        // report `user == ""` for this form; comparing against empty
        // avoids a false-positive on URLs that have no real credentials
        // to leak.
        let hasUser = !(url.user?.isEmpty ?? true)
        let hasPassword = !(url.password?.isEmpty ?? true)
        if hasUser || hasPassword {
            throw Error.containsCredentials
        }
        return url
    }
}
