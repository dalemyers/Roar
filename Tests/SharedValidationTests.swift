import XCTest
import ArgumentParser
@testable import roar

/// Pins the contract of `SharedValidation.requireNonBlank`, the helper
/// every flag-validation site funnels through. The wider validators
/// (`Send.validateRequestIdentifier`, `Dismiss.validateIdentifiers`,
/// etc.) layer their own length / context checks on top, but the
/// trim-and-reject-empty / control-character rules all live here —
/// pinning them once means a regression in the helper trips this file
/// rather than every consumer's test.
final class SharedValidationTests: XCTestCase {

    func testNilReturnsNil() throws {
        // The "flag was not passed" case must round-trip unchanged so
        // callers can chain `if let trimmed = try ...` against the
        // optional result without an extra branch.
        let result = try SharedValidation.requireNonBlank(
            nil, flag: "--example")
        XCTAssertNil(result)
    }

    func testValidValueReturnsTrimmed() throws {
        // Whitespace stripping is part of the contract — callers that
        // pass the value straight through to a downstream API rely on
        // it (e.g. `parseScheduleDate` feeds the trimmed value to
        // `ISO8601DateFormatter`).
        let result = try SharedValidation.requireNonBlank(
            "  hello  ", flag: "--example")
        XCTAssertEqual(result, "hello")
    }

    func testValueWithoutPaddingReturnsAsIs() throws {
        let result = try SharedValidation.requireNonBlank(
            "hello", flag: "--example")
        XCTAssertEqual(result, "hello")
    }

    func testEmptyStringRejected() {
        XCTAssertThrowsError(
            try SharedValidation.requireNonBlank("", flag: "--example")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testWhitespaceOnlyRejected() {
        XCTAssertThrowsError(
            try SharedValidation.requireNonBlank("   ", flag: "--example")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testTabAndNewlineOnlyRejected() {
        // `whitespacesAndNewlines` includes tabs and newlines — the
        // trim must strip both before the emptiness check, otherwise
        // `"\t\n"` would slip through as a "non-empty string."
        XCTAssertThrowsError(
            try SharedValidation.requireNonBlank("\t\n", flag: "--example")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testErrorMessageIncludesFlagName() {
        // The flag-name interpolation is the whole reason this helper
        // exists in shared code — every consumer relies on it to
        // personalise the diagnostic. A regression that hardcoded
        // `"--example"` (e.g. via copy-paste) would silently break
        // every other call site, so pin the format here.
        XCTAssertThrowsError(
            try SharedValidation.requireNonBlank("", flag: "--my-flag")
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("--my-flag"),
                "error must mention the flag name; got: \(message)"
            )
        }
    }

    func testEmptyAdviceAppendedToMessage() {
        // The optional advice text is how each call site adds a
        // flag-specific pointer (e.g. "Provide a UTI like
        // public.png"). Pin that the helper actually appends it.
        XCTAssertThrowsError(
            try SharedValidation.requireNonBlank(
                "", flag: "--my-flag",
                emptyAdvice: "Try a UTI like public.png.")
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("Try a UTI like public.png."),
                "error must include the advice; got: \(message)"
            )
        }
    }

    // MARK: - Control-character screen (opt-in)

    func testControlCharactersAllowedWhenScreenOff() throws {
        // The control-char screen is opt-in because some flags
        // (e.g. `--body`, `--repeat`) legitimately carry whitespace
        // control chars. Pin that with the screen off, a NUL or tab
        // passes — only the trim+empty rule fires.
        XCTAssertEqual(
            try SharedValidation.requireNonBlank("a\0b", flag: "--example"),
            "a\0b"
        )
        XCTAssertEqual(
            try SharedValidation.requireNonBlank("a\tb", flag: "--example"),
            "a\tb"
        )
    }

    func testNullByteRejectedWhenScreenOn() {
        XCTAssertThrowsError(
            try SharedValidation.requireNonBlank(
                "build\0other", flag: "--example",
                rejectControlCharacters: true)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testNewlineRejectedWhenScreenOn() {
        XCTAssertThrowsError(
            try SharedValidation.requireNonBlank(
                "line1\nline2", flag: "--example",
                rejectControlCharacters: true)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testTabRejectedWhenScreenOn() {
        XCTAssertThrowsError(
            try SharedValidation.requireNonBlank(
                "a\tb", flag: "--example",
                rejectControlCharacters: true)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testEscRejectedWhenScreenOn() {
        // ESC (`\u{001B}`) is in `CharacterSet.controlCharacters` and
        // is the prefix of every ANSI escape sequence — letting one
        // through into a notification body lets a same-bundle-id
        // process inject terminal control codes downstream.
        XCTAssertThrowsError(
            try SharedValidation.requireNonBlank(
                "a\u{001B}[2Jb", flag: "--example",
                rejectControlCharacters: true)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testControlCharacterErrorIncludesFlagName() {
        XCTAssertThrowsError(
            try SharedValidation.requireNonBlank(
                "x\0y", flag: "--special-flag",
                rejectControlCharacters: true)
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("--special-flag"),
                "control-char error must mention the flag; got: \(message)"
            )
        }
    }

    func testControlCharacterAdviceAppended() {
        // Sites with a more specific hazard (e.g. attachment paths
        // feeding `lstat`) can override the post-comma advice. Pin
        // that the override is actually emitted in the message.
        XCTAssertThrowsError(
            try SharedValidation.requireNonBlank(
                "x\0y", flag: "--example",
                rejectControlCharacters: true,
                controlCharactersAdvice: "NUL truncates downstream filesystem calls.")
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("NUL truncates downstream filesystem calls."),
                "control-char error must include the override; got: \(message)"
            )
        }
    }

    // MARK: - Trim semantics

    func testTrimAppliesBeforeControlCharacterScreen() throws {
        // Trim strips trailing/leading whitespace before the
        // emptiness check, but the control-character screen runs
        // against the *original* value — otherwise a value like
        // `"  text  "` whose interior contained no control chars
        // would still trip if the trim erroneously preserved them.
        // Conversely, leading/trailing whitespace itself is in
        // `controlCharacters` (e.g. tab), so a value of `" name "`
        // (regular spaces — not in controlCharacters) must pass the
        // screen and round-trip as "name".
        let result = try SharedValidation.requireNonBlank(
            " name ", flag: "--example",
            rejectControlCharacters: true)
        XCTAssertEqual(result, "name")
    }
}
