import XCTest
import ArgumentParser
@testable import roar

final class AttachmentPathTests: XCTestCase {

    // MARK: - Accept

    func testAcceptsAbsolutePath() throws {
        try Send.validateAttachmentPath("/tmp/foo.png")
    }

    func testAcceptsCurrentUserTildePath() throws {
        try Send.validateAttachmentPath("~/Pictures/foo.png")
    }

    func testAcceptsBareTilde() throws {
        // Bare `~` expands to the user's home — valid input even if it
        // points at a directory rather than a file (the downstream
        // attachment init handles that).
        try Send.validateAttachmentPath("~")
    }

    func testAcceptsRelativePath() throws {
        try Send.validateAttachmentPath("foo.png")
    }

    func testAcceptsHTTPSURLSyntactically() throws {
        // `validateAttachmentPath` is the syntactic guard (empty,
        // `~user`, `file://host`). It accepts http(s) URLs because the
        // semantic "remote URLs are not supported, use curl"
        // rejection lives in `validateAttachmentExistsIfLocal` so
        // that error can include curl-first guidance referencing the
        // user's input. See AttachmentRemoteRejectedTests for that
        // end-to-end pinning.
        try Send.validateAttachmentPath("https://example.com/cat.png")
    }

    func testAcceptsFileURLWithEmptyHost() throws {
        // RFC 8089 says local file URLs use an empty host (or none) —
        // `file:///tmp/foo.png` parses with host == nil.
        try Send.validateAttachmentPath("file:///tmp/foo.png")
    }

    // MARK: - Reject (empty)

    func testRejectsEmptyString() {
        XCTAssertThrowsError(try Send.validateAttachmentPath("")) {
            assertIsValidationError($0)
        }
    }

    // MARK: - Reject (~user paths)

    func testRejectsUserTildePath() {
        // `~someone/foo` is not handled by NSString.expandingTildeInPath
        // — would silently fail downstream. Reject up front.
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("~root/foo.png")
        ) { assertIsValidationError($0) }
    }

    func testRejectsTildeFollowedByLetter() {
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("~admin")
        ) { assertIsValidationError($0) }
    }

    // MARK: - Reject (file:// with host)

    func testRejectsFileURLWithHost() {
        // `file://server/share/foo.png` parses `server` as the URL host
        // — Foundation never reaches the filesystem with it. Two-slash
        // file URLs are ambiguous on the path branch, so reject.
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("file://server/share/foo.png")
        ) { assertIsValidationError($0) }
    }

    func testRejectsFileURLWithTildeAsHost() {
        // `file://~/foo.png` is a common user mistake: Foundation
        // treats the `~` as the host and the rest as the path.
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("file://~/foo.png")
        ) { assertIsValidationError($0) }
    }

    func testRejectsUppercaseFileURLWithHost() {
        // The previous implementation matched `file://` by
        // `hasPrefix`, which is case-sensitive — `FILE://server/x`
        // would silently bypass the host check and fail opaquely in
        // makeAttachment. Scheme comparison must be case-insensitive.
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("FILE://server/share/foo.png")
        ) { assertIsValidationError($0) }
    }

    func testRejectsMixedCaseFileURLWithHost() {
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("File://server/share/foo.png")
        ) { assertIsValidationError($0) }
    }

    /// POSIX-locale folding is load-bearing for the scheme
    /// comparison. Default `String.lowercased()` is locale-aware:
    /// under `LANG=tr_TR.UTF-8`, "FILE".lowercased() folds the `I`
    /// to dotless ı and would NOT match the ASCII `"file"`
    /// literal, letting a Turkish-locale process slip
    /// `FILE://server/share` past the host check.
    ///
    /// This test cannot easily mutate the process's default locale,
    /// so it pins the contract two ways:
    ///   1. End-to-end: `FILE://host/share` is rejected even under
    ///      the upper-case spelling.
    ///   2. The Turkish-locale fold of `"FILE"` is observably
    ///      different from the POSIX fold (`"fıle"` vs `"file"`).
    ///      A regression that swapped the implementation back to
    ///      plain `.lowercased()` would compile and pass (1) on a
    ///      non-Turkish build but would silently bypass on a
    ///      Turkish-locale process; (2) is the underlying
    ///      observation that makes the POSIX fold the right
    ///      defence.
    func testTurkishLocaleDoesNotBypassFileURLHostRejection() {
        // (1) End-to-end.
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("FILE://server/share/foo.png")
        ) { assertIsValidationError($0) }
        // (2) Underlying locale observation.
        let turkish = "FILE".lowercased(with: Locale(identifier: "tr_TR"))
        let posix = "FILE".lowercased(with: Locale(identifier: "en_US_POSIX"))
        XCTAssertNotEqual(turkish, "file",
                          "Turkish fold should differ from ASCII 'file'")
        XCTAssertEqual(posix, "file",
                       "POSIX fold must equal ASCII 'file'")
    }

    // MARK: - Reject (URL-shaped local paths)

    /// `https:/notes.png` (single slash, no authority) parses with
    /// scheme `https` and no host. Without the malformed-URL
    /// rejection, the classifier would route this to `.localPath`
    /// and hand the literal string to `lstat`, surfacing as an opaque
    /// "no such file" error. Pin the up-front rejection so the user
    /// sees a clear "did you mean a URL?" diagnostic.
    func testRejectsHTTPSWithSingleSlash() {
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("https:/notes.png")
        ) { assertIsValidationError($0) }
    }

    func testRejectsHTTPWithSingleSlash() {
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("http:/notes.png")
        ) { assertIsValidationError($0) }
    }

    func testRejectsFTPWithSingleSlash() {
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("ftp:/server/notes.png")
        ) { assertIsValidationError($0) }
    }

    /// `https:notes.png` (NO slashes after the colon) also parses with
    /// scheme `https` and no authority. Same rationale as the
    /// single-slash variant: the classifier would otherwise hand the
    /// literal string to `lstat`, surfacing as an opaque "no such file"
    /// error. The current implementation catches this via the
    /// `!path.contains("://")` clause; pin it explicitly so a future
    /// refactor that tightens the check doesn't drop the no-slash
    /// shape.
    func testRejectsHTTPSWithNoSlash() {
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("https:notes.png")
        ) { assertIsValidationError($0) }
    }

    /// Bare `https:` is a degenerate URL — scheme with no path and no
    /// authority. Likely a user typo (e.g. paste truncation); reject
    /// up front rather than letting it filter through to `lstat` as a
    /// literal filename `https:`.
    func testRejectsHTTPSColonOnly() {
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("https:")
        ) { assertIsValidationError($0) }
    }

    /// `release:v1.png` — a filename containing a colon — has the
    /// same shape (no `://`) but is NOT a remote scheme. The
    /// classifier already routes it to `.localPath`. Pin that the
    /// malformed-URL rejection only catches the http/https/ftp
    /// case, not arbitrary colon-bearing filenames.
    func testAcceptsColonBearingFilename() throws {
        try Send.validateAttachmentPath("release:v1.png")
    }

    // MARK: - Reject (control characters)

    /// NUL truncates at the `lstat`/`realpath`/`readlink` C-bridge.
    /// A value like `"/tmp/safe.png\0/etc/passwd"` would otherwise
    /// probe `/tmp/safe.png` and silently attach a different
    /// location. Mirrors the screening on `--identifier`,
    /// `--thread-id`, `--sound`, and `--exec`.
    func testRejectsNullByte() {
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("/tmp/safe.png\0/etc/passwd")
        ) { assertIsValidationError($0) }
    }

    func testRejectsNewline() {
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("/tmp/foo\nbar.png")
        ) { assertIsValidationError($0) }
    }

    func testRejectsTab() {
        XCTAssertThrowsError(
            try Send.validateAttachmentPath("/tmp/foo\tbar.png")
        ) { assertIsValidationError($0) }
    }

    // MARK: - Decoded-path bypass regression

    /// Regression for the `file:` percent-encoded control-character
    /// bypass.
    ///
    /// `validateAttachmentPath` screens the RAW input for control
    /// characters, but Foundation's `URL.path` decodes `%0A` / `%0D`
    /// / `%09` (LF / CR / TAB) when extracting the path component
    /// of a `file:` URL. So `file:///tmp/x%0Ay.png` passes the raw
    /// screen (all printable ASCII) but the downstream classifier
    /// produces a `.localPath` containing a literal LF byte that
    /// then reaches `lstat`. The `rejectControlCharactersInDecodedPath`
    /// re-screen catches the decoded form.
    ///
    /// (`%00` and `%2F` are NOT decoded by Foundation — those
    /// bypasses do not work; this test pins the ones that do.)
    func testRejectsPercentEncodedNewlineInFileURL() {
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal(
                "file:///tmp/x%0Ay.png")
        ) { assertIsValidationError($0) }
    }

    func testRejectsPercentEncodedCRInFileURL() {
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal(
                "file:///tmp/x%0Dy.png")
        ) { assertIsValidationError($0) }
    }

    func testRejectsPercentEncodedTabInFileURL() {
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal(
                "file:///tmp/x%09y.png")
        ) { assertIsValidationError($0) }
    }

    /// Pure-function pin on the decoded-path screen so a regression
    /// surfaces here even if the validator's call ordering shifts.
    func testRejectControlCharactersInDecodedPathRejectsLF() {
        XCTAssertThrowsError(
            try Send.rejectControlCharactersInDecodedPath("/tmp/x\ny.png")
        ) { assertIsValidationError($0) }
    }

    func testRejectControlCharactersInDecodedPathRejectsNUL() {
        XCTAssertThrowsError(
            try Send.rejectControlCharactersInDecodedPath("/tmp/x\0y.png")
        ) { assertIsValidationError($0) }
    }

    func testRejectControlCharactersInDecodedPathAcceptsPlain() throws {
        try Send.rejectControlCharactersInDecodedPath("/tmp/foo.png")
    }

    // MARK: - Helpers

    private func assertIsValidationError(
        _ error: Error,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            error is ValidationError,
            "Expected ValidationError, got \(type(of: error)): \(error)",
            file: file, line: line
        )
    }
}
