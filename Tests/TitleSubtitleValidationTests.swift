import XCTest
import ArgumentParser
@testable import roar

/// Pin the narrowed contract of `validateTitle` / `validateSubtitle`:
/// only NUL is rejected (the XPC C-string bridge truncation hazard),
/// not the broader `CharacterSet.controlCharacters`. Newlines and tabs
/// are legitimate display content in a free-form user-facing string;
/// rejecting them would block legitimate banner layouts.
///
/// The check existed historically as a `.controlCharacters` screen,
/// which was overly broad. This file locks in the narrower NUL-only
/// behaviour so a future contributor can't silently widen it back.
final class TitleSubtitleValidationTests: XCTestCase {

    // MARK: - validateTitle

    func testRejectsNULInTitle() {
        XCTAssertThrowsError(try Send.validateTitle("hello\0world")) { error in
            XCTAssertTrue(error is ValidationError, "got \(type(of: error))")
            XCTAssertTrue(
                "\(error)".contains("NUL"),
                "error should mention NUL; got \(error)"
            )
        }
    }

    func testAcceptsNewlineInTitle() throws {
        // Newlines render as soft line breaks in banner layouts; legit.
        try Send.validateTitle("Build\nresult")
    }

    func testAcceptsTabInTitle() throws {
        // Tabs are display-only formatting; UN renders them as
        // whitespace. No truncation risk.
        try Send.validateTitle("col1\tcol2")
    }

    func testAcceptsUnicodeTitle() throws {
        // Emoji and other non-ASCII glyphs land in the title verbatim;
        // the C-string bridge handles UTF-8 fine — NUL is the only
        // byte that truncates.
        try Send.validateTitle("⚠️ heads up")
    }

    func testAcceptsPlainTitle() throws {
        // Sanity: the common case still passes.
        try Send.validateTitle("Build complete")
    }

    // MARK: - validateSubtitle

    func testRejectsNULInSubtitle() {
        XCTAssertThrowsError(try Send.validateSubtitle("a\0b")) { error in
            XCTAssertTrue(error is ValidationError, "got \(type(of: error))")
            XCTAssertTrue(
                "\(error)".contains("NUL"),
                "error should mention NUL; got \(error)"
            )
        }
    }

    func testAcceptsNewlineInSubtitle() throws {
        try Send.validateSubtitle("line1\nline2")
    }

    func testAcceptsNilSubtitle() throws {
        // `nil` means the flag wasn't passed — fast-path.
        try Send.validateSubtitle(nil)
    }

    // MARK: - visibleContentByteCap

    /// `--title` is bounded at `visibleContentByteCap`. Strings at
    /// the cap are accepted; strings one byte over are rejected so
    /// a multi-MB title piped from a shell variable cannot flood
    /// the UN XPC payload.
    func testRejectsOversizedTitle() {
        let oversized = String(
            repeating: "a", count: Send.visibleContentByteCap + 1)
        XCTAssertThrowsError(try Send.validateTitle(oversized)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testAcceptsTitleAtCap() throws {
        let atCap = String(
            repeating: "a", count: Send.visibleContentByteCap)
        try Send.validateTitle(atCap)
    }

    func testRejectsOversizedSubtitle() {
        let oversized = String(
            repeating: "a", count: Send.visibleContentByteCap + 1)
        XCTAssertThrowsError(try Send.validateSubtitle(oversized)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    /// UTF-8 byte length, not grapheme count: a string of N emoji
    /// (each 4 bytes) at `visibleContentByteCap / 4 + 1` graphemes
    /// is over the byte cap and must reject. This pins the cap as
    /// a transport-cost guard, not a grapheme-count guard.
    func testRejectsOversizedUTF8Title() {
        // U+1F600 (😀) is 4 UTF-8 bytes. (cap / 4) + 1 graphemes
        // exceeds the cap on the wire.
        let emoji = "\u{1F600}"
        let count = Send.visibleContentByteCap / 4 + 1
        let oversized = String(repeating: emoji, count: count)
        XCTAssertThrowsError(try Send.validateTitle(oversized)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsOversizedResolvedBody() {
        let oversized = String(
            repeating: "a", count: Send.visibleContentByteCap + 1)
        XCTAssertThrowsError(
            try Send.validateResolvedBodySize(oversized)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }
}
