import XCTest
@testable import roar

/// Tests for the pure allow-list URL validator. The validator does
/// NOT maintain a hardcoded deny list; every dangerous scheme is
/// dangerous only because someone might enable it. The default
/// allow-list (http/https/mailto) is web/email-only; everything else
/// requires the caller to extend the allow-list explicitly.
final class URLValidationTests: XCTestCase {

    // MARK: - Accept (default allow-list)

    func testAcceptsHTTPSWithHost() throws {
        let url = try URLValidation.parse("https://example.com")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "example.com")
    }

    func testAcceptsHTTPWithHostAndPath() throws {
        let url = try URLValidation.parse("http://example.com/some/path?q=1")
        XCTAssertEqual(url.host, "example.com")
        XCTAssertEqual(url.path, "/some/path")
    }

    func testAcceptsMailto() throws {
        // mailto has no host but does have a path, which is what the
        // missingTarget check should accept.
        let url = try URLValidation.parse("mailto:foo@bar.com")
        XCTAssertEqual(url.scheme, "mailto")
    }

    func testTrimsWhitespace() throws {
        let url = try URLValidation.parse("  https://example.com  \n")
        XCTAssertEqual(url.host, "example.com")
    }

    // MARK: - Extended allow-list

    /// The validator accepts any scheme passed in `allowedSchemes`.
    /// Callers are responsible for deciding which schemes to admit;
    /// `Send.run` builds its allow-list from `defaultOpenSchemes`
    /// plus any `--allow-url-scheme` values the user typed.
    func testAcceptsCustomSchemeWhenExplicitlyAllowed() throws {
        let url = try URLValidation.parse(
            "vscode://file/path",
            allowedSchemes: ["http", "https", "mailto", "vscode"])
        XCTAssertEqual(url.scheme, "vscode")
    }

    func testAcceptsCustomSchemeWithBuildAllowList() throws {
        let allowList = try URLValidation.buildAllowList(
            additions: ["ssh"])
        let url = try URLValidation.parse(
            "ssh://example.com", allowedSchemes: allowList)
        XCTAssertEqual(url.scheme, "ssh")
    }

    func testCustomAllowedSchemes() throws {
        let url = try URLValidation.parse(
            "ssh://example.com", allowedSchemes: ["ssh"])
        XCTAssertEqual(url.scheme, "ssh")
    }

    // MARK: - Reject

    func testRejectsEmpty() {
        assertParseError(input: "") {
            if case .empty = $0 { return true }
            return false
        }
    }

    func testRejectsWhitespaceOnly() {
        assertParseError(input: "   \n\t") {
            if case .empty = $0 { return true }
            return false
        }
    }

    func testRejectsSchemeless() {
        // "lol" parses but has no scheme — must fail.
        assertParseError(input: "lol") {
            switch $0 {
            case .missingScheme, .malformed: return true
            default: return false
            }
        }
    }

    func testRejectsHostlessHTTPS() {
        // "https://" has scheme but no host and no path — would silently
        // fail at click time, so reject up front.
        assertParseError(input: "https://") {
            if case .missingTarget = $0 { return true }
            return false
        }
    }

    func testRejectsSingleSlashHTTPS() {
        // "https:/" parses with path == "/" (not empty) — earlier the
        // missingTarget guard tested only `path.isEmpty` and let this
        // through. NSWorkspace.open silently no-ops on it.
        assertParseError(input: "https:/") {
            if case .missingTarget = $0 { return true }
            return false
        }
    }

    func testRejectsSchemeNotInAllowList() {
        // `ssh://` is not in the default allow-list (http/https/mailto).
        // The validator surfaces a `disallowedScheme` error naming the
        // exact allow-list — there's no "always rejected" deny floor.
        assertParseError(input: "ssh://example.com/foo") {
            if case .disallowedScheme(let scheme, _) = $0, scheme == "ssh" { return true }
            return false
        }
    }

    /// `file://` is not in the default allow-list, so it's rejected.
    /// A user who genuinely wants to open a local file via a click
    /// (rare) must opt in with `--allow-url-scheme file` and accept
    /// the click-to-LaunchServices-execution risk.
    func testRejectsFileByDefault() {
        assertParseError(input: "file:///tmp/foo.command") {
            if case .disallowedScheme(let scheme, _) = $0, scheme == "file" {
                return true
            }
            return false
        }
    }

    /// Each historically-dangerous scheme is rejected by default
    /// because it isn't in `defaultOpenSchemes`. These tests pin the
    /// default behaviour so a regression that silently adds e.g.
    /// `javascript` to the default allow-list surfaces here.
    func testRejectsJavascriptByDefault() {
        assertParseError(input: "javascript:alert(1)") {
            if case .disallowedScheme(let scheme, _) = $0,
               scheme == "javascript" { return true }
            return false
        }
    }

    func testRejectsDataByDefault() {
        assertParseError(
            input: "data:text/html,<script>alert(1)</script>"
        ) {
            if case .disallowedScheme(let scheme, _) = $0, scheme == "data" {
                return true
            }
            return false
        }
    }

    func testRejectsAFPByDefault() {
        assertParseError(input: "afp://server/share") {
            if case .disallowedScheme(let scheme, _) = $0, scheme == "afp" {
                return true
            }
            return false
        }
    }

    func testRejectsTelByDefault() {
        // `tel:` triggers a phone call on click via FaceTime; not in
        // the default allow-list so it requires opt-in.
        assertParseError(input: "tel:+1-555-0000") {
            if case .disallowedScheme(let scheme, _) = $0, scheme == "tel" {
                return true
            }
            return false
        }
    }

    /// Case-insensitivity matters: HTML tolerates uppercase
    /// `JAVASCRIPT:` and Safari accepts it. The validator
    /// lowercases the scheme via `en_US_POSIX` before allow-list
    /// matching, so uppercase forms hit the same outcome as
    /// lowercase.
    func testSchemeMatchingIsCaseInsensitive() {
        assertParseError(input: "JaVaScRiPt:alert(1)") {
            if case .disallowedScheme(let scheme, _) = $0,
               scheme == "javascript" { return true }
            return false
        }
    }

    /// `String.lowercased()` is locale-aware: under
    /// `LANG=tr_TR.UTF-8`, "FILE".lowercased() folds to "fıle" (with
    /// U+0131 LATIN SMALL LETTER DOTLESS I) — which would NOT match
    /// the lowercase ASCII "file". The validator pins the locale to
    /// `en_US_POSIX` (which always uses ASCII folding) to keep
    /// allow-list lookup locale-invariant.
    ///
    /// (1) End-to-end: uppercase ASCII scheme normalizes to the
    /// lowercase form the allow-list expects.
    /// (2) The Turkish locale's fold of the same string produces a
    /// *different* result. If a future regression switched back to
    /// plain `.lowercased()` on a Turkish-locale build, the Turkish
    /// fold would not match the allow-list entry.
    func testTurkishLocaleDoesNotBypassMatching() {
        let allowList: Set<String> = ["http", "https", "mailto"]
        assertParseError(
            input: "FILE:///tmp/x",
            allowedSchemes: allowList
        ) {
            if case .disallowedScheme(let scheme, _) = $0, scheme == "file" {
                return true
            }
            return false
        }

        let turkish = "FILE".lowercased(with: Locale(identifier: "tr_TR"))
        let posix = "FILE".lowercased(with: Locale(identifier: "en_US_POSIX"))
        XCTAssertNotEqual(turkish, "file",
                          "Turkish fold should differ from ASCII 'file'")
        XCTAssertEqual(posix, "file",
                       "POSIX fold must equal ASCII 'file'")
    }

    // MARK: - Embedded credentials

    /// `user:password@host` userinfo is stored in `roar.open.url`'s
    /// payload and replayed at click time. Errors mentioning the URL
    /// would leak the credentials to stderr / terminal scrollback /
    /// CI logs. Reject up front.
    func testRejectsUserAndPasswordInURL() {
        assertParseError(input: "https://user:secret@example.com/path") {
            if case .containsCredentials = $0 { return true }
            return false
        }
    }

    func testRejectsUserOnlyInURL() {
        // GitHub-style `https://token@host/...` — the username slot
        // alone is enough to carry a bearer token.
        assertParseError(input: "https://token@example.com/path") {
            if case .containsCredentials = $0 { return true }
            return false
        }
    }

    /// The rejection applies regardless of which scheme is in the
    /// allow-list — a custom scheme with embedded credentials is just
    /// as leak-prone.
    func testRejectsCredentialsRegardlessOfAllowList() {
        assertParseError(
            input: "x-myapp://user:secret@host/path",
            allowedSchemes: ["http", "https", "mailto", "x-myapp"]
        ) {
            if case .containsCredentials = $0 { return true }
            return false
        }
    }

    /// `mailto:foo@bar.com` has no host and the `@` is part of the
    /// path, not userinfo. Foundation's URL exposes `.user == nil` for
    /// this form, so the rejection should NOT fire.
    func testAcceptsMailtoWithAtSign() throws {
        let url = try URLValidation.parse("mailto:foo@bar.com")
        XCTAssertEqual(url.scheme, "mailto")
    }

    /// Empty-string userinfo (`https://@host/`) carries the `@`
    /// separator but no credentials. Some Foundation versions report
    /// `url.user == ""` for this form while others return nil; the
    /// validator's `!(url.user?.isEmpty ?? true)` guard collapses both
    /// to "no credentials present."
    func testAcceptsEmptyUserinfoAtSign() throws {
        let url = try URLValidation.parse("https://@example.com/path")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "example.com")
    }

    /// The rejection's error message must not echo the raw URL —
    /// echoing it would re-leak the credentials we just refused to
    /// store. Pin that the description is credential-free.
    func testCredentialsErrorMessageDoesNotEchoCredentials() {
        let raw = "https://leakeduser:leakedsecret@example.com/path"
        do {
            _ = try URLValidation.parse(raw)
            XCTFail("Expected throw")
        } catch let error as URLValidation.Error {
            let message = error.description
            XCTAssertFalse(message.contains("leakeduser"),
                           "Error must not echo username; got: \(message)")
            XCTAssertFalse(message.contains("leakedsecret"),
                           "Error must not echo password; got: \(message)")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Scheme-name validator (--allow-url-scheme input syntax)

    func testValidateSchemeNameAcceptsRFC3986Shapes() throws {
        XCTAssertEqual(try URLValidation.validateSchemeName("vscode"),
                       "vscode")
        XCTAssertEqual(try URLValidation.validateSchemeName("x-myapp"),
                       "x-myapp")
        XCTAssertEqual(
            try URLValidation.validateSchemeName("git+ssh"),
            "git+ssh")
        XCTAssertEqual(try URLValidation.validateSchemeName("ABC"),
                       "abc",
                       "Names are lowercased via en_US_POSIX")
    }

    func testValidateSchemeNameRejectsLeadingDigit() {
        XCTAssertThrowsError(
            try URLValidation.validateSchemeName("1abc")
        ) { error in
            guard case URLValidation.Error.invalidSchemeName = error else {
                return XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testValidateSchemeNameRejectsSpace() {
        XCTAssertThrowsError(
            try URLValidation.validateSchemeName("java script")
        ) { error in
            guard case URLValidation.Error.invalidSchemeName = error else {
                return XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testValidateSchemeNameRejectsComma() {
        // Comma would break the userInfo serialisation separator;
        // reject at validation time rather than silently splitting
        // the value at runtime.
        XCTAssertThrowsError(
            try URLValidation.validateSchemeName("foo,bar")
        ) { error in
            guard case URLValidation.Error.invalidSchemeName = error else {
                return XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testValidateSchemeNameRejectsNUL() {
        XCTAssertThrowsError(
            try URLValidation.validateSchemeName("abc\0def")
        ) { error in
            guard case URLValidation.Error.invalidSchemeName = error else {
                return XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testValidateSchemeNameRejectsEmpty() {
        XCTAssertThrowsError(try URLValidation.validateSchemeName(""))
    }

    // MARK: - Allow-list build / serialisation round-trip

    func testBuildAllowListUnionsWithDefault() throws {
        let combined = try URLValidation.buildAllowList(
            additions: ["vscode", "slack"])
        XCTAssertTrue(combined.isSuperset(of: URLValidation.defaultOpenSchemes))
        XCTAssertTrue(combined.contains("vscode"))
        XCTAssertTrue(combined.contains("slack"))
    }

    func testBuildAllowListLowercases() throws {
        let combined = try URLValidation.buildAllowList(
            additions: ["VSCODE"])
        XCTAssertTrue(combined.contains("vscode"))
        XCTAssertFalse(combined.contains("VSCODE"))
    }

    func testBuildAllowListRejectsBogusName() {
        XCTAssertThrowsError(
            try URLValidation.buildAllowList(additions: ["bogus name"])
        )
    }

    /// Round-trip: a serialised allow-list must deserialise back to
    /// the same set. The click-time handler relies on this so the
    /// allow-list the click validates against equals the allow-list
    /// the send agreed to.
    func testSerializeRoundTrip() {
        let original: Set<String> = ["http", "https", "mailto", "vscode"]
        let serialised = URLValidation.serializeAllowList(original)
        let restored = URLValidation.deserializeAllowList(serialised)
        XCTAssertEqual(restored, original)
    }

    func testSerializeIsDeterministic() {
        // The serialisation orders the schemes — same set → same
        // string. Helps testing pin equality without depending on
        // hash ordering.
        let s1 = URLValidation.serializeAllowList(["b", "a", "c"])
        let s2 = URLValidation.serializeAllowList(["c", "b", "a"])
        XCTAssertEqual(s1, s2)
        XCTAssertEqual(s1, "a,b,c")
    }

    func testDeserializeRejectsMalformed() {
        // A spoofed value with an embedded bogus scheme name
        // deserialises to `nil`. Caller treats `nil` as "no
        // allow-list" and falls back to defaults (fail-closed).
        XCTAssertNil(URLValidation.deserializeAllowList("http,bogus scheme,mailto"))
    }

    func testDeserializeIgnoresEmpty() {
        // Trailing / leading / repeated commas produce empty entries
        // that should be dropped.
        let restored = URLValidation.deserializeAllowList(",http,,https,")
        XCTAssertEqual(restored, ["http", "https"])
    }

    // MARK: - Helpers

    /// Run `URLValidation.parse(input)` and assert the thrown error
    /// matches `match`. Using a closure-of-error instead of an
    /// `Equatable` conformance avoids declaring a retroactive
    /// conformance on `URLValidation.Error` from the test target.
    private func assertParseError(
        input: String,
        allowedSchemes: Set<String> = URLValidation.defaultOpenSchemes,
        file: StaticString = #file,
        line: UInt = #line,
        match: (URLValidation.Error) -> Bool
    ) {
        XCTAssertThrowsError(
            try URLValidation.parse(input, allowedSchemes: allowedSchemes),
            file: file, line: line
        ) { error in
            guard let err = error as? URLValidation.Error else {
                return XCTFail("Wrong error type: \(error)", file: file, line: line)
            }
            XCTAssertTrue(match(err), "Error did not match expected case: \(err)", file: file, line: line)
        }
    }
}
