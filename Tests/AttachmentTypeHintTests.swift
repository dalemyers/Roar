import XCTest
import ArgumentParser
import UserNotifications
@testable import roar

/// Pin the behaviour of `--attachment-type-hint`:
///
/// * Empty / whitespace-only values are rejected (UN distinguishes
///   `nil` from `""` and the latter is almost never intentional).
/// * Setting the hint without any `--attachment` is rejected — UN
///   silently ignores attachment options with no attachment, so this
///   would otherwise be a silent no-op.
/// * The builder emits `UNNotificationAttachmentOptionsTypeHintKey`
///   with the value preserved verbatim.
final class AttachmentTypeHintTests: XCTestCase {

    // MARK: - validateAttachmentTypeHint

    func testNilHintAccepted() throws {
        try Send.validateAttachmentTypeHint(nil, attachments: [])
        try Send.validateAttachmentTypeHint(nil, attachments: ["/tmp/x.png"])
    }

    func testNonEmptyHintWithAttachmentAccepted() throws {
        try Send.validateAttachmentTypeHint(
            "public.png", attachments: ["/tmp/x.png"])
    }

    func testEmptyHintRejected() {
        XCTAssertThrowsError(try Send.validateAttachmentTypeHint(
            "", attachments: ["/tmp/x.png"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testWhitespaceOnlyHintRejected() {
        XCTAssertThrowsError(try Send.validateAttachmentTypeHint(
            "  \t\n  ", attachments: ["/tmp/x.png"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testHintWithoutAttachmentRejected() {
        XCTAssertThrowsError(try Send.validateAttachmentTypeHint(
            "public.png", attachments: [])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - buildAttachmentOptions emits the typeHint key

    func testBuilderEmitsTypeHintKey() {
        let options = Send.buildAttachmentOptions(
            noThumbnail: false,
            thumbnailTime: nil,
            typeHint: "public.png")
        XCTAssertNotNil(options)
        XCTAssertEqual(
            options?[UNNotificationAttachmentOptionsTypeHintKey] as? String,
            "public.png"
        )
        XCTAssertNil(options?[UNNotificationAttachmentOptionsThumbnailHiddenKey])
        XCTAssertNil(options?[UNNotificationAttachmentOptionsThumbnailTimeKey])
    }

    func testBuilderCombinesTypeHintWithThumbnailFlags() {
        let options = Send.buildAttachmentOptions(
            noThumbnail: true,
            thumbnailTime: 4.0,
            typeHint: "public.mpeg-4")
        XCTAssertEqual(options?.count, 3)
        XCTAssertEqual(
            options?[UNNotificationAttachmentOptionsTypeHintKey] as? String,
            "public.mpeg-4"
        )
        XCTAssertEqual(
            options?[UNNotificationAttachmentOptionsThumbnailHiddenKey] as? Bool,
            true
        )
        XCTAssertEqual(
            options?[UNNotificationAttachmentOptionsThumbnailTimeKey] as? NSNumber,
            NSNumber(value: 4.0)
        )
    }

    func testBuilderReturnsNilWhenAllOptionsAbsent() {
        let options = Send.buildAttachmentOptions(
            noThumbnail: false,
            thumbnailTime: nil,
            typeHint: nil)
        XCTAssertNil(options)
    }

    func testNilTypeHintProducesNoTypeHintKey() {
        let options = Send.buildAttachmentOptions(
            noThumbnail: true,
            thumbnailTime: nil,
            typeHint: nil)
        XCTAssertNotNil(options)
        XCTAssertNil(options?[UNNotificationAttachmentOptionsTypeHintKey])
    }

    func testTypeHintPreservesVerbatimValue() {
        // Validation only screens for emptiness — the UTI's syntax is
        // the framework's problem. Pin that the builder doesn't
        // normalise, lowercase, or otherwise rewrite the user input.
        let hint = "dyn.ah62d4rv4ge81g4w4"
        let options = Send.buildAttachmentOptions(
            noThumbnail: false,
            thumbnailTime: nil,
            typeHint: hint)
        XCTAssertEqual(
            options?[UNNotificationAttachmentOptionsTypeHintKey] as? String,
            hint
        )
    }
}
