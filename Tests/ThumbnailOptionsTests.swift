import XCTest
import ArgumentParser
import UserNotifications
@testable import roar

/// Pinned behaviour for `--no-thumbnail` and `--thumbnail-time`:
///
/// * Time must be finite and non-negative when provided.
/// * Either flag without `--attachment` is a user mistake — the UN
///   framework silently ignores attachment options on attachment-less
///   notifications, which would surprise the user.
/// * The options dict generated for UN must use the documented keys.
final class ThumbnailOptionsTests: XCTestCase {

    // MARK: - validateThumbnailTime

    func testNilTimeAccepted() throws {
        try Send.validateThumbnailTime(nil)
    }

    func testZeroTimeAccepted() throws {
        try Send.validateThumbnailTime(0)
    }

    func testPositiveTimeAccepted() throws {
        try Send.validateThumbnailTime(12.5)
    }

    func testNegativeTimeRejected() {
        XCTAssertThrowsError(try Send.validateThumbnailTime(-0.001)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testNaNTimeRejected() {
        XCTAssertThrowsError(try Send.validateThumbnailTime(.nan)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testInfiniteTimeRejected() {
        XCTAssertThrowsError(try Send.validateThumbnailTime(.infinity)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    // MARK: - validateThumbnailFlagsRequireAttachment

    func testNoFlagsWithoutAttachmentIsFine() throws {
        try Send.validateThumbnailFlagsRequireAttachment(
            attachments: [], noThumbnail: false, thumbnailTime: nil)
    }

    func testAttachmentWithFlagsIsFine() throws {
        try Send.validateThumbnailFlagsRequireAttachment(
            attachments: ["/tmp/foo.png"],
            noThumbnail: true,
            thumbnailTime: 1.0)
    }

    func testMultipleAttachmentsWithFlagsIsFine() throws {
        // `--no-thumbnail` and `--thumbnail-time` apply uniformly when
        // multiple `--attachment` values are passed; the validator
        // accepts any non-empty list.
        try Send.validateThumbnailFlagsRequireAttachment(
            attachments: ["/tmp/a.png", "/tmp/b.mp4"],
            noThumbnail: false,
            thumbnailTime: 3.0)
    }

    func testNoThumbnailWithoutAttachmentRejected() {
        XCTAssertThrowsError(
            try Send.validateThumbnailFlagsRequireAttachment(
                attachments: [], noThumbnail: true, thumbnailTime: nil)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testThumbnailTimeWithoutAttachmentRejected() {
        XCTAssertThrowsError(
            try Send.validateThumbnailFlagsRequireAttachment(
                attachments: [], noThumbnail: false, thumbnailTime: 5.0)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - validateAttachmentCount

    func testEmptyAttachmentListAccepted() throws {
        try Send.validateAttachmentCount([])
    }

    func testSingleAttachmentAccepted() throws {
        try Send.validateAttachmentCount(["/tmp/a.png"])
    }

    func testCountAtLimitAccepted() throws {
        let list = (0..<Send.maximumAttachmentCount).map { "/tmp/\($0).png" }
        try Send.validateAttachmentCount(list)
    }

    func testCountOverLimitRejected() {
        let list = (0...Send.maximumAttachmentCount).map { "/tmp/\($0).png" }
        XCTAssertThrowsError(try Send.validateAttachmentCount(list)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    // MARK: - buildAttachmentOptions

    func testBuilderReturnsNilForNoFlags() {
        let options = Send.buildAttachmentOptions(
            noThumbnail: false, thumbnailTime: nil)
        XCTAssertNil(options)
    }

    func testBuilderEmitsHiddenKeyForNoThumbnail() {
        let options = Send.buildAttachmentOptions(
            noThumbnail: true, thumbnailTime: nil)
        XCTAssertNotNil(options)
        XCTAssertEqual(
            options?[UNNotificationAttachmentOptionsThumbnailHiddenKey] as? Bool,
            true
        )
        XCTAssertNil(options?[UNNotificationAttachmentOptionsThumbnailTimeKey])
    }

    func testBuilderEmitsTimeKeyForThumbnailTime() {
        let options = Send.buildAttachmentOptions(
            noThumbnail: false, thumbnailTime: 7.5)
        XCTAssertNotNil(options)
        XCTAssertEqual(
            options?[UNNotificationAttachmentOptionsThumbnailTimeKey] as? NSNumber,
            NSNumber(value: 7.5)
        )
        XCTAssertNil(options?[UNNotificationAttachmentOptionsThumbnailHiddenKey])
    }

    func testBuilderEmitsBothKeys() {
        let options = Send.buildAttachmentOptions(
            noThumbnail: true, thumbnailTime: 2.0)
        XCTAssertEqual(options?.count, 2)
        XCTAssertEqual(
            options?[UNNotificationAttachmentOptionsThumbnailHiddenKey] as? Bool,
            true
        )
        XCTAssertEqual(
            options?[UNNotificationAttachmentOptionsThumbnailTimeKey] as? NSNumber,
            NSNumber(value: 2.0)
        )
    }
}
