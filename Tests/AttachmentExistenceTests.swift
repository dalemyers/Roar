import XCTest
import ArgumentParser
@testable import roar

/// Pin the local-file existence check applied to `--attachment`.
/// Without this, a typo like `--attachment foo.png` (wrong cwd)
/// only surfaces when `UNNotificationAttachment.init` rejects the URL,
/// producing an opaque "The file couldn't be opened" downstream.
///
/// Test-isolation risk: `testColonBearingFilenameIsTreatedAsLocalPath`
/// mutates the process-wide working directory via
/// `FileManager.default.changeCurrentDirectoryPath` because the
/// validator under test (`validateAttachmentExistsIfLocal`) resolves
/// relative paths against `getcwd()`. XCTest runs tests on a shared
/// process, so a parallel test that reads cwd (none today, but a
/// future addition) would see whichever directory this test happened
/// to be in. The restore-cwd `defer` re-anchors before the next test,
/// but interleaved-parallel execution is not guarded. The proper fix
/// is to thread a `cwd: String` parameter through
/// `validateAttachmentExistsIfLocal` so the test can pass an explicit
/// directory — that's a Wave 4+ production refactor, deliberately
/// deferred from this wave.
final class AttachmentExistenceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("roar-attachment-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Accept

    func testAcceptsExistingAbsolutePath() throws {
        let file = tempDir.appendingPathComponent("image.png")
        try Data().write(to: file)
        try Send.validateAttachmentExistsIfLocal(file.path)
    }

    func testAcceptsExistingFileURL() throws {
        let file = tempDir.appendingPathComponent("image.png")
        try Data().write(to: file)
        try Send.validateAttachmentExistsIfLocal("file://\(file.path)")
    }

    /// Remote URLs are rejected at validation with a clear
    /// curl-first message. `--attachment` does not fetch over the
    /// network; we want the user to see the actionable guidance
    /// rather than an opaque downstream failure.
    func testRejectsHTTPSWithCurlGuidance() {
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal("https://example.com/cat.png")
        ) { error in
            XCTAssertTrue(error is ValidationError, "got \(type(of: error)): \(error)")
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("curl"),
                "Error should mention curl as the workaround; got: \(message)"
            )
        }
    }

    func testRejectsHTTPWithCurlGuidance() {
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal("http://example.com/cat.png")
        ) { error in
            XCTAssertTrue(error is ValidationError, "got \(type(of: error)): \(error)")
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("curl"),
                "Error should mention curl as the workaround; got: \(message)"
            )
        }
    }

    /// `release:v1.png` parses with a synthetic `release` scheme, but
    /// `makeAttachment` treats it as a local relative path (the `:` is
    /// a legal filename character on macOS). The existence check must
    /// follow the same classification — both branches are exercised by
    /// creating the file (must be accepted) and then removing it (must
    /// be rejected with a missing-file error). Asserting only the
    /// missing-file rejection would pass even if the validator
    /// silently mis-classified `release:v1.png` as a remote URL and
    /// short-circuited.
    func testColonBearingFilenameIsTreatedAsLocalPath() throws {
        // Temporarily switch to the test temp dir so the colon-bearing
        // filename resolves there rather than against an unrelated cwd
        // that might have a stray file with this name.
        //
        // Defer-ordering note: register the restore-cwd defer *before*
        // calling chdir, so a future edit that adds an XCTFail-and-
        // return between the two cannot bypass cleanup. The capture
        // of `originalCwd` happens before chdir, so the defer always
        // restores the directory we came from — even on the
        // chdir-failed path (where the defer no-ops, since cwd never
        // changed). The previous shape (`defer` after `guard`) was
        // technically safe but fragile to reorderings; this is the
        // discipline used elsewhere in the test suite.
        let fm = FileManager.default
        let originalCwd = fm.currentDirectoryPath
        defer { _ = fm.changeCurrentDirectoryPath(originalCwd) }
        guard fm.changeCurrentDirectoryPath(tempDir.path) else {
            XCTFail("Could not chdir to tempDir")
            return
        }

        let filename = "release:v1.png"
        let absolutePath = tempDir.appendingPathComponent(filename).path

        // Missing — must throw with a ValidationError (proving the
        // validator treated this as a local path, not a remote URL).
        XCTAssertFalse(fm.fileExists(atPath: absolutePath))
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal(filename)
        ) { error in
            XCTAssertTrue(
                error is ValidationError,
                "Expected ValidationError, got \(type(of: error)): \(error)"
            )
        }

        // Present — must NOT throw (proving the validator can resolve
        // the colon-bearing relative path against cwd).
        try Data().write(to: URL(fileURLWithPath: absolutePath))
        XCTAssertNoThrow(
            try Send.validateAttachmentExistsIfLocal(filename)
        )
    }

    // MARK: - Reject

    func testRejectsMissingAbsolutePath() {
        let missing = tempDir.appendingPathComponent("does-not-exist.png").path
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal(missing)
        ) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testRejectsMissingFileURL() {
        let missing = tempDir.appendingPathComponent("does-not-exist.png").path
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal("file://\(missing)")
        ) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testRejectsMissingRelativePath() {
        // Relative path in cwd — no setup means the file doesn't exist.
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal(
                "nonexistent-\(UUID().uuidString).png")
        ) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }
}
