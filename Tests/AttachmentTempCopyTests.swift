import XCTest
import ArgumentParser
import UserNotifications
@testable import roar

/// Pin the temp-copy behaviour of `makeAttachment`.
///
/// `UNNotificationAttachment.init(identifier:url:options:)` on macOS
/// *moves* the source file into the system's attachment store at
/// `add(_:)` time (different from iOS, where it copies). Without an
/// intermediate copy, a user who runs
/// `roar send --attachment ~/Pictures/photo.png` finds their photo
/// has vanished after the notification posts.
///
/// `makeAttachment` therefore copies the user's file into
/// `NSTemporaryDirectory()` and hands UN the temp path. UN moves the
/// temp copy; the user's original is untouched.
///
/// These tests pin the contract:
///   * The URL `makeAttachment` returns is in `NSTemporaryDirectory()`,
///     NOT the user's path.
///   * The user's original file still exists after `makeAttachment`
///     returns (UN doesn't move at `init` time — only at `add(_:)` —
///     but the test pins that we never even pass the original URL).
///   * The temp copy preserves the original filename's extension so
///     UN's UTI inference still works when `--attachment-type-hint`
///     isn't set.
final class AttachmentTempCopyTests: XCTestCase {

    private var tempDir: URL! // swiftlint:disable:this implicitly_unwrapped_optional

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("roar-tempcopy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// The URL returned via the produced `UNNotificationAttachment`
    /// lives under `NSTemporaryDirectory()` — proof we copied the
    /// user's file to a staging location rather than handing UN the
    /// user's original path directly.
    func testAttachmentURLIsInTempDirectory() async throws {
        let source = tempDir.appendingPathComponent("user-photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)  // PNG magic
        let cmd = try Send.parse(["--title", "test", "--attachment", source.path])
        let attachment = try await cmd.makeAttachment(from: source.path)
        let attachmentPath = attachment.url.path
        let tempRoot = (NSTemporaryDirectory() as NSString).standardizingPath
        XCTAssertTrue(
            attachmentPath.hasPrefix(tempRoot),
            "Attachment URL must live under NSTemporaryDirectory; got \(attachmentPath)"
        )
        XCTAssertNotEqual(
            attachmentPath, source.path,
            "Attachment URL must NOT be the user's original path"
        )
    }

    /// The user's source file still exists after `makeAttachment`
    /// returns. UN's move happens at `add(_:)` time, not at
    /// attachment-init time — but the contract this test pins is
    /// "we never pass the user's path to UN," so even when UN
    /// later moves, it moves the temp copy.
    func testUserOriginalSurvivesMakeAttachment() async throws {
        let source = tempDir.appendingPathComponent("keep-me.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
        let cmd = try Send.parse(["--title", "test", "--attachment", source.path])
        _ = try await cmd.makeAttachment(from: source.path)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "User's original file should still exist after makeAttachment; got nothing at \(source.path)"
        )
    }

    /// The temp copy preserves the source filename. UN uses the
    /// filename's extension for UTI inference when
    /// `--attachment-type-hint` isn't supplied; a temp name like
    /// `attachment.bin` would change how the system renders the
    /// preview. The original basename rides through.
    func testTempCopyPreservesFilename() async throws {
        let source = tempDir.appendingPathComponent("specific-name.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: source)  // JPEG magic
        let cmd = try Send.parse(["--title", "test", "--attachment", source.path])
        let attachment = try await cmd.makeAttachment(from: source.path)
        XCTAssertEqual(
            attachment.url.lastPathComponent,
            "specific-name.jpg",
            "Temp copy should keep the original basename for UTI inference"
        )
    }

    /// Per-attachment temp directory is unique — a single
    /// invocation with multiple `--attachment` flags produces
    /// distinct paths so the copies don't clobber each other.
    func testMultipleAttachmentsProduceDistinctTempCopies() async throws {
        let a = tempDir.appendingPathComponent("first.png")
        let b = tempDir.appendingPathComponent("second.png")
        try Data([0x89]).write(to: a)
        try Data([0x89]).write(to: b)
        let cmd = try Send.parse([
            "--title", "test",
            "--attachment", a.path,
            "--attachment", b.path,
        ])
        let attachA = try await cmd.makeAttachment(from: a.path)
        let attachB = try await cmd.makeAttachment(from: b.path)
        XCTAssertNotEqual(
            attachA.url.deletingLastPathComponent(),
            attachB.url.deletingLastPathComponent(),
            "Each attachment should get its own temp subdirectory"
        )
    }
}
