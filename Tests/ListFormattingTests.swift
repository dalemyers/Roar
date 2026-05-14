import XCTest
@testable import roar

/// Pinned behaviour for the pure formatting helpers in `List`. The
/// `formatDelivered` / `formatPending` paths build a
/// `UNNotification` / `UNNotificationRequest` (which we can't easily
/// instantiate in a test outside an end-to-end run), so we only cover
/// the user-visible primitives here.
final class ListFormattingTests: XCTestCase {

    // MARK: - flatten

    func testFlattenLeavesPlainStringUnchanged() {
        XCTAssertEqual(List.flatten("Hello world"), "Hello world")
    }

    func testFlattenReplacesNewlines() {
        XCTAssertEqual(List.flatten("line one\nline two"), "line one line two")
    }

    func testFlattenReplacesCarriageReturns() {
        XCTAssertEqual(List.flatten("first\rsecond"), "first second")
    }

    func testFlattenReplacesTabs() {
        XCTAssertEqual(List.flatten("col1\tcol2"), "col1 col2")
    }

    func testFlattenReplacesCRLF() {
        // CRLF -> two spaces, not one — flatten is a per-char swap.
        // This is acceptable because the result is still single-line.
        XCTAssertEqual(List.flatten("a\r\nb"), "a  b")
    }

    func testFlattenLeavesUnicodeIntact() {
        // Non-ASCII characters that aren't line separators stay put.
        XCTAssertEqual(List.flatten("café 🚀"), "café 🚀")
    }

    /// Cocoa text rendering treats U+2028 (LINE SEPARATOR) and
    /// U+2029 (PARAGRAPH SEPARATOR) as line breaks; without stripping
    /// them, a notification body containing them would spill across
    /// rows when piped to anything line-oriented.
    func testFlattenReplacesLineSeparator() {
        XCTAssertEqual(List.flatten("a\u{2028}b"), "a b")
    }

    func testFlattenReplacesParagraphSeparator() {
        XCTAssertEqual(List.flatten("a\u{2029}b"), "a b")
    }

    func testFlattenReplacesNEL() {
        // U+0085 (NEXT LINE) — used in EBCDIC-derived sources, still
        // treated as a line break by some renderers.
        XCTAssertEqual(List.flatten("a\u{0085}b"), "a b")
    }

    func testFlattenReplacesVerticalTabAndFormFeed() {
        XCTAssertEqual(List.flatten("a\u{000B}b"), "a b")
        XCTAssertEqual(List.flatten("a\u{000C}b"), "a b")
    }

    /// ESC (U+001B) is the start byte of every ANSI CSI sequence. A
    /// notification title containing `\x1B[2J` would erase the screen
    /// of anyone running `roar list` if it leaked through unredacted.
    /// Pin that flatten strips it.
    func testFlattenReplacesESC() {
        XCTAssertEqual(List.flatten("a\u{001B}[2Jb"), "a [2Jb")
    }

    /// BEL (U+0007) — terminals beep when this lands in stdout. Not a
    /// security issue but an annoyance, and the C0 sweep covers it
    /// for free.
    func testFlattenReplacesBEL() {
        XCTAssertEqual(List.flatten("a\u{0007}b"), "a b")
    }

    /// NUL (U+0000) — many line-oriented tools (`awk`, `sed`) treat
    /// NUL as an end-of-string and silently truncate. Replacing with
    /// space keeps the row intact.
    func testFlattenReplacesNUL() {
        XCTAssertEqual(List.flatten("a\u{0000}b"), "a b")
    }

    /// Backspace (U+0008) — a terminal would erase the preceding
    /// character. In a TSV listing this lets a malicious title overprint
    /// a previous column. Scrubbed.
    func testFlattenReplacesBackspace() {
        XCTAssertEqual(List.flatten("a\u{0008}b"), "a b")
    }

    /// DEL (U+007F) — not a C0 control but historically used by
    /// terminals to erase. Same risk shape as backspace.
    func testFlattenReplacesDEL() {
        XCTAssertEqual(List.flatten("a\u{007F}b"), "a b")
    }

    /// Sanity check that the full C0 sweep covers every byte in the
    /// 0x00..0x1F range — a regression that re-narrowed the scrub to
    /// only the historical seven would otherwise slip through.
    func testFlattenReplacesAllC0Controls() {
        for byte in 0x00...0x1F {
            // `Unicode.Scalar(UInt8)` is the non-failable initialiser
            // — every byte 0x00...0xFF is a valid scalar. Using it
            // instead of the failable `Unicode.Scalar(Int)?` overload
            // avoids a force-unwrap on a value that's unwrappable by
            // construction.
            let scalar = Unicode.Scalar(UInt8(byte))
            let input = "a\(Character(scalar))b"
            XCTAssertEqual(
                List.flatten(input), "a b",
                "C0 byte 0x\(String(byte, radix: 16, uppercase: true)) not scrubbed"
            )
        }
    }

    // MARK: - isoDate

    func testIsoDateRoundTripsKnownInstant() {
        // 1700000000 = 2023-11-14T22:13:20Z. Round-trip via the same
        // formatter shape `isoDate` produces.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let rendered = List.isoDate(date)
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(parser.date(from: rendered), date)
    }
}
