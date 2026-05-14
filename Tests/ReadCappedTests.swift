import XCTest
import ArgumentParser
@testable import roar

/// Exercise `Send.readCapped` against a `Pipe`-backed `FileHandle` so the
/// production cap / overflow / truncation paths are covered without
/// depending on actual stdin.
final class ReadCappedTests: XCTestCase {

    private var pipe: Pipe!

    override func setUp() {
        super.setUp()
        pipe = Pipe()
    }

    override func tearDown() {
        // `try?` because the writer side may already be closed by the
        // test body. The reader side is always closed here so the
        // descriptor cannot leak across tests.
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
        pipe = nil
        super.tearDown()
    }

    // MARK: - Complete reads (writer closes before / at the cap)

    func testReturnsCompleteWhenWriterClosesBelowCap() throws {
        let payload = Data("hello".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        let result = try Send.readCapped(
            from: pipe.fileHandleForReading,
            maxBytes: 100,
            overflowProbeTimeoutMs: 500
        )
        XCTAssertEqual(result, .complete(payload))
    }

    func testReturnsCompleteWhenWriterClosesAtExactlyCap() throws {
        // The writer sent exactly `maxBytes` and then closed. `poll`
        // sees POLLHUP, the probe `read` returns empty, and the result
        // is `.complete` — NOT `.possiblyTruncated`.
        let payload = Data(repeating: 0x41, count: 100)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        let result = try Send.readCapped(
            from: pipe.fileHandleForReading,
            maxBytes: 100,
            overflowProbeTimeoutMs: 500
        )
        XCTAssertEqual(result, .complete(payload))
    }

    func testReturnsCompleteOnImmediateEOF() throws {
        // No data at all, writer closes. The first `read(upToCount:)`
        // returns nil/empty and we exit with `.complete(empty)`.
        try pipe.fileHandleForWriting.close()

        let result = try Send.readCapped(
            from: pipe.fileHandleForReading,
            maxBytes: 100,
            overflowProbeTimeoutMs: 500
        )
        XCTAssertEqual(result, .complete(Data()))
    }

    // MARK: - Overflow (writer sent more than cap)

    func testThrowsOnOverflow() throws {
        let payload = Data(repeating: 0x41, count: 200)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        XCTAssertThrowsError(
            try Send.readCapped(
                from: pipe.fileHandleForReading,
                maxBytes: 100,
                overflowProbeTimeoutMs: 500
            )
        ) { error in
            XCTAssertTrue(
                error is ValidationError,
                "Expected ValidationError, got \(type(of: error)): \(error)"
            )
        }
    }

    // MARK: - Possibly truncated (writer paused at the cap)

    func testReturnsPossiblyTruncatedWhenWriterPausesAtCap() throws {
        // Fill the pipe to exactly the cap and DO NOT close the writer.
        // The probe `poll` should time out — there are no further bytes
        // and no POLLHUP — and the function returns `.possiblyTruncated`.
        // Cap is small so the test finishes quickly; the probe timeout
        // is also short for the same reason.
        let payload = Data(repeating: 0x42, count: 50)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        // Intentionally do NOT close the writer here.

        let result = try Send.readCapped(
            from: pipe.fileHandleForReading,
            maxBytes: 50,
            overflowProbeTimeoutMs: 100
        )
        XCTAssertEqual(result, .possiblyTruncated(payload))
    }

    // MARK: - Result helpers

    func testDataAccessorReturnsSameBytesForBothCases() {
        let bytes = Data("x".utf8)
        XCTAssertEqual(Send.CappedReadResult.complete(bytes).data, bytes)
        XCTAssertEqual(Send.CappedReadResult.possiblyTruncated(bytes).data, bytes)
    }

    // MARK: - I/O failure

    /// Reading from a file handle whose descriptor has been closed
    /// produces an I/O error from `FileHandle.read(upToCount:)`. The
    /// `readCapped` contract surfaces that as a `ValidationError`
    /// rather than swallowing it with `try?` and returning empty
    /// (the pre-fix behaviour that masked legitimate I/O failures as
    /// silent truncation).
    func testThrowsValidationErrorOnIOFailure() throws {
        // Close the reader side BEFORE handing it to readCapped, so
        // any subsequent read raises an I/O error. We then nil out the
        // pipe reference so tearDown doesn't try to double-close.
        let reader = pipe.fileHandleForReading
        try reader.close()
        XCTAssertThrowsError(
            try Send.readCapped(
                from: reader,
                maxBytes: 100,
                overflowProbeTimeoutMs: 500
            )
        ) { error in
            XCTAssertTrue(
                error is ValidationError,
                "Expected ValidationError, got \(type(of: error)): \(error)"
            )
        }
    }

    // MARK: - rejectNULInBody

    /// NUL truncates at every C-string bridge downstream consumers
    /// might use (`os_log`, JSON loggers, XPC). A body containing
    /// NUL would silently appear truncated in some surfaces but
    /// intact in others — reject up front rather than chase a
    /// half-truncated bug later.
    func testRejectNULInBodyRejectsNUL() {
        XCTAssertThrowsError(
            try Send.rejectNULInBody("hello\0world", source: "--body")
        ) { error in
            XCTAssertTrue(
                error is ValidationError,
                "Expected ValidationError, got \(type(of: error)): \(error)"
            )
        }
    }

    func testRejectNULInBodyRejectsStdinSource() {
        XCTAssertThrowsError(
            try Send.rejectNULInBody("hello\0world", source: "Piped input")
        ) { error in
            // Error message must mention the source so users know
            // whether to look at their --body flag or their pipe.
            guard let validation = error as? ValidationError else {
                XCTFail("Wrong error type: \(error)")
                return
            }
            XCTAssertTrue(
                "\(validation)".contains("Piped input"),
                "Error did not mention source: \(validation)"
            )
        }
    }

    func testRejectNULInBodyAcceptsNULFreeContent() throws {
        try Send.rejectNULInBody("hello world", source: "--body")
        // Embedded newlines, tabs, and other control chars are NOT
        // NUL and pass this check. They get trimmed/normalised
        // elsewhere; `rejectNULInBody` is narrowly about the
        // C-string truncation hazard.
        try Send.rejectNULInBody("line one\nline two\twith tab", source: "--body")
    }

    func testRejectNULInBodyAcceptsNil() throws {
        // `nil` is what `resolveBody` passes when the user gave no
        // body at all; the "missing body" error fires elsewhere.
        // This check must not double-error on nil.
        try Send.rejectNULInBody(nil, source: "--body")
    }

    // MARK: - decodePipedBodyUTF8

    /// Valid UTF-8 bytes (including multi-byte sequences) decode
    /// verbatim. Pin both the ASCII fast-path and a multi-byte
    /// sequence so a future "treat input as latin-1" regression
    /// would visibly mangle the round-trip.
    func testDecodePipedBodyUTF8AcceptsValidASCII() throws {
        let decoded = try Send.decodePipedBodyUTF8(Data("hello".utf8))
        XCTAssertEqual(decoded, "hello")
    }

    func testDecodePipedBodyUTF8AcceptsValidMultibyte() throws {
        // "héllo" — the `é` is `0xC3 0xA9` in UTF-8; decoding as any
        // other 8-bit codepage would produce a different string.
        let decoded = try Send.decodePipedBodyUTF8(Data("héllo".utf8))
        XCTAssertEqual(decoded, "héllo")
    }

    /// Pin the H6 branch: a raw `\xff\xfe\x80` byte sequence is not
    /// valid UTF-8 (lone continuation bytes / invalid lead). Without
    /// the explicit decode error, `resolveBody`'s `?? ""` fallback
    /// would collapse to the misleading "Provide --body" message —
    /// surface the actual encoding problem instead.
    func testDecodePipedBodyUTF8RejectsInvalidBytes() {
        let invalid = Data([0xFF, 0xFE, 0x80])
        XCTAssertThrowsError(try Send.decodePipedBodyUTF8(invalid)) { error in
            guard let validation = error as? ValidationError else {
                XCTFail("Expected ValidationError, got \(type(of: error)): \(error)")
                return
            }
            // The message must mention "UTF-8" so users know the bytes
            // reached the process but were unparseable, vs. an empty
            // pipe. Loose match to survive copy edits.
            XCTAssertTrue(
                "\(validation)".contains("UTF-8"),
                "Error message did not mention UTF-8: \(validation)"
            )
        }
    }

    /// Empty input decodes to an empty string (NOT a throw). The
    /// "missing body" check fires later in `resolveBody`; the decode
    /// step must not pre-empt it on the empty-pipe path.
    func testDecodePipedBodyUTF8AcceptsEmpty() throws {
        let decoded = try Send.decodePipedBodyUTF8(Data())
        XCTAssertEqual(decoded, "")
    }
}
