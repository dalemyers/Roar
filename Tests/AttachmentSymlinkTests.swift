import XCTest
import ArgumentParser
@testable import roar

/// Pin the symlink / non-regular-file rejection on local
/// `--attachment` paths. Without this guard, a path like
/// `/tmp/foo.png` pointing at `~/.ssh/id_rsa` would pass
/// `fileExists(atPath:)` and have its target copied into the per-app
/// UN attachment store — readable by anyone with screen access and
/// extractable from the attachment store on disk.
final class AttachmentSymlinkTests: XCTestCase {

    // XCTestCase fixture assigned in `setUpWithError`. See
    // `AttachmentExistenceTests` for the disable rationale.
    private var tempDir: URL! // swiftlint:disable:this implicitly_unwrapped_optional

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("roar-symlink-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Send-time validator (ValidationError path)

    func testValidatorAcceptsRegularFile() throws {
        let file = tempDir.appendingPathComponent("real.png")
        try Data().write(to: file)
        XCTAssertNoThrow(
            try Send.validateAttachmentExistsIfLocal(file.path)
        )
    }

    func testValidatorRejectsSymlinkToRegularFile() throws {
        // Target is a real, readable file. The validator must still
        // refuse — we cannot prove the user typed this link
        // intentionally vs. having it pre-staged by an attacker.
        let target = tempDir.appendingPathComponent("target.png")
        try Data().write(to: target)
        let link = tempDir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal(link.path)
        ) { error in
            XCTAssertTrue(error is ValidationError,
                          "Expected ValidationError, got \(type(of: error))")
            let msg = String(describing: error)
            XCTAssertTrue(msg.contains("symbolic link") || msg.contains("symlink"),
                          "Expected symlink mention in: \(msg)")
        }
    }

    func testValidatorRejectsDanglingSymlink() throws {
        // Pointer to a file that doesn't exist. The validator should
        // surface "no longer accessible" rather than the generic
        // "does not exist" so the user can tell symlink-trouble apart
        // from typos.
        let link = tempDir.appendingPathComponent("dangling.png")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "/nonexistent/abs/path.png")

        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal(link.path)
        ) { error in
            XCTAssertTrue(error is ValidationError)
            // Note: a dangling symlink's `lstat` succeeds (the link
            // itself is the file `lstat` reports on), so the error
            // here is the "symbolic link" refusal, not "missing".
            let msg = String(describing: error)
            XCTAssertTrue(msg.contains("symbolic link") || msg.contains("symlink"))
        }
    }

    func testValidatorRejectsDirectory() throws {
        // `--attachment /tmp` would previously pass `fileExists`
        // (a directory exists) and only fail downstream at
        // `UNNotificationAttachment.init` with an opaque error.
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal(tempDir.path)
        ) { error in
            XCTAssertTrue(error is ValidationError)
            let msg = String(describing: error)
            XCTAssertTrue(msg.contains("regular file") || msg.contains("0o"),
                          "Expected file-type mention in: \(msg)")
        }
    }

    func testValidatorRejectsMissingPath() throws {
        let missing = tempDir.appendingPathComponent("does-not-exist.png").path
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal(missing)
        ) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    // MARK: - Last-chance check (AttachmentError path)

    /// `rejectIfUnsafeForAttachment` is the TOCTOU defence run by
    /// `makeAttachment` just before handing the URL to
    /// `UNNotificationAttachment.init`. Even if the file passed the
    /// send-time validator, an attacker who can win the race could
    /// swap a regular file for a symlink between then and now — this
    /// last-chance check shrinks the window.
    func testRejectIfUnsafeAcceptsRegularFile() throws {
        let file = tempDir.appendingPathComponent("real.png")
        try Data().write(to: file)
        XCTAssertNoThrow(try Send.rejectIfUnsafeForAttachment(path: file.path))
    }

    func testRejectIfUnsafeRejectsSymlink() throws {
        let target = tempDir.appendingPathComponent("target.png")
        try Data().write(to: target)
        let link = tempDir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try Send.rejectIfUnsafeForAttachment(path: link.path)
        ) { error in
            // Different error type than the send-time path —
            // `AttachmentError` so the consumer can distinguish a
            // race-time refusal from a send-time validation refusal.
            guard let attErr = error as? Send.AttachmentError else {
                return XCTFail("Expected AttachmentError, got \(type(of: error))")
            }
            if case .unsafeLocalAttachment(_, let reason) = attErr {
                XCTAssertEqual(reason, .symlink)
            } else {
                XCTFail("Expected .unsafeLocalAttachment(.symlink), got \(attErr)")
            }
        }
    }

    func testRejectIfUnsafeRejectsDirectory() throws {
        XCTAssertThrowsError(
            try Send.rejectIfUnsafeForAttachment(path: tempDir.path)
        ) { error in
            guard let attErr = error as? Send.AttachmentError else {
                return XCTFail("Expected AttachmentError, got \(type(of: error))")
            }
            if case .unsafeLocalAttachment(_, let reason) = attErr {
                if case .notRegularFile = reason { return }
                XCTFail("Expected .notRegularFile reason, got \(reason)")
            } else {
                XCTFail("Expected .unsafeLocalAttachment, got \(attErr)")
            }
        }
    }

    func testRejectIfUnsafeRejectsMissing() throws {
        let missing = tempDir.appendingPathComponent("not-here").path
        XCTAssertThrowsError(
            try Send.rejectIfUnsafeForAttachment(path: missing)
        ) { error in
            guard let attErr = error as? Send.AttachmentError else {
                return XCTFail("Expected AttachmentError, got \(type(of: error))")
            }
            if case .unsafeLocalAttachment(_, let reason) = attErr {
                if case .missing = reason { return }
                XCTFail("Expected .missing reason, got \(reason)")
            } else {
                XCTFail("Expected .unsafeLocalAttachment, got \(attErr)")
            }
        }
    }
}
