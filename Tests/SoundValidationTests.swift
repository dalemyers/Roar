import XCTest
import ArgumentParser
@testable import roar

final class SoundValidationTests: XCTestCase {

    /// Per-test temp directory the helper points at instead of the
    /// system sound locations. Built fresh in `setUp` so each test gets
    /// a clean slate.
    ///
    /// XCTestCase fixture assigned in `setUpWithError`. See
    /// `AttachmentExistenceTests` for the disable rationale.
    private var soundDir: URL! // swiftlint:disable:this implicitly_unwrapped_optional

    override func setUpWithError() throws {
        try super.setUpWithError()
        soundDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("roar-sound-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: soundDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: soundDir)
        try super.tearDownWithError()
    }

    // MARK: - Accept

    func testAcceptsDefault() throws {
        // "default" maps to UNNotificationSound.default at runtime; no
        // filesystem probe should happen and the directories arg is
        // ignored.
        try Send.validateSoundName(
            "default",
            directories: ["/nonexistent"],
            extensions: ["aiff"]
        )
    }

    func testAcceptsExistingSoundFile() throws {
        try writeSound(named: "Glass", ext: "aiff")
        try Send.validateSoundName(
            "Glass",
            directories: [soundDir.path],
            extensions: ["aiff"]
        )
    }

    func testAcceptsSoundUnderAlternativeExtension() throws {
        // The helper should walk every extension before giving up.
        try writeSound(named: "Glass", ext: "caf")
        try Send.validateSoundName(
            "Glass",
            directories: [soundDir.path],
            extensions: ["aiff", "caf"]
        )
    }

    func testAcceptsSoundInSecondDirectory() throws {
        try writeSound(named: "Glass", ext: "aiff")
        try Send.validateSoundName(
            "Glass",
            directories: ["/nonexistent", soundDir.path],
            extensions: ["aiff"]
        )
    }

    // MARK: - Reject (path syntax)

    func testRejectsNameWithSlash() {
        XCTAssertThrowsError(
            try Send.validateSoundName("../etc/passwd", directories: [soundDir.path])
        ) { assertIsValidationError($0) }
    }

    func testRejectsNameStartingWithDot() {
        XCTAssertThrowsError(
            try Send.validateSoundName(".hidden", directories: [soundDir.path])
        ) { assertIsValidationError($0) }
    }

    func testRejectsBareDotDot() {
        // ".." starts with a dot — caught by the leading-dot guard.
        XCTAssertThrowsError(
            try Send.validateSoundName("..", directories: [soundDir.path])
        ) { assertIsValidationError($0) }
    }

    func testRejectsBackslash() {
        // Backslash is a legal filename character on macOS but allowing
        // it in a sound name is inconsistent with the "plain name"
        // intent and lets `..\foo`-style probes leak through.
        XCTAssertThrowsError(
            try Send.validateSoundName("Glass\\foo", directories: [soundDir.path])
        ) { assertIsValidationError($0) }
    }

    func testRejectsNullByte() {
        // NUL is the worst case: the C-string bridge for
        // `fileExists(atPath:)` truncates at NUL, so a name like
        // "Glass\0/etc/passwd" would probe an unrelated path.
        XCTAssertThrowsError(
            try Send.validateSoundName("Glass\0foo", directories: [soundDir.path])
        ) { assertIsValidationError($0) }
    }

    func testRejectsControlCharacter() {
        // BEL (0x07) is a representative non-NUL control character.
        XCTAssertThrowsError(
            try Send.validateSoundName("Glass\u{0007}", directories: [soundDir.path])
        ) { assertIsValidationError($0) }
    }

    func testRejectsNewlineInName() {
        // Newline is a control character; should be rejected.
        XCTAssertThrowsError(
            try Send.validateSoundName("Glass\nFunk", directories: [soundDir.path])
        ) { assertIsValidationError($0) }
    }

    // MARK: - Reject (not found)

    func testRejectsMissingSound() {
        XCTAssertThrowsError(
            try Send.validateSoundName(
                "Nonexistent",
                directories: [soundDir.path],
                extensions: ["aiff"]
            )
        ) { assertIsValidationError($0) }
    }

    func testRejectsWhenDirectoriesEmpty() {
        XCTAssertThrowsError(
            try Send.validateSoundName("Glass", directories: [])
        ) { assertIsValidationError($0) }
    }

    // MARK: - Helpers

    /// Touch an empty file named `<sound>.<ext>` in the temp directory.
    /// The validator only checks `fileExists`; content does not matter.
    private func writeSound(named sound: String, ext: String) throws {
        let url = soundDir
            .appendingPathComponent(sound)
            .appendingPathExtension(ext)
        try Data().write(to: url)
    }

    /// All rejection paths throw `ArgumentParser.ValidationError`.
    /// Asserting on the type keeps the test rule visible without
    /// pinning to message text.
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
