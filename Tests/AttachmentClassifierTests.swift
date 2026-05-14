import XCTest
@testable import roar

/// Pin the shared classifier that decides which bucket an
/// `--attachment` value falls into: local filesystem path,
/// rejected http/https URL, or some-other-scheme. The classifier is
/// shared between `validateAttachmentExistsIfLocal` (send-time
/// existence / symlink check) and `makeAttachment` (the actual load).
/// Previously two independent classifiers diverged on
/// `file:relative/path` (no slashes) and let it through validation but
/// hit `makeAttachment` with an opaque error.
final class AttachmentClassifierTests: XCTestCase {

    // MARK: - Rejected remote URLs (curl-first guidance)

    func testHTTPSAuthorityClassifiesAsRejectedRemote() {
        guard case .rejectedRemoteURL(let scheme) = Send.classifyAttachment(
            "https://example.com/cat.png"
        ) else {
            return XCTFail("Expected .rejectedRemoteURL")
        }
        XCTAssertEqual(scheme, "https")
    }

    func testHTTPAuthorityClassifiesAsRejectedRemote() {
        guard case .rejectedRemoteURL(let scheme) = Send.classifyAttachment(
            "http://example.com/cat.png"
        ) else {
            return XCTFail("Expected .rejectedRemoteURL")
        }
        XCTAssertEqual(scheme, "http")
    }

    func testUppercaseHTTPSClassifiesAsRejectedRemote() {
        // POSIX-locale fold: an uppercase scheme must still classify
        // as the rejected-remote bucket so the curl-first error wins
        // over the more generic "other scheme" path.
        guard case .rejectedRemoteURL = Send.classifyAttachment(
            "HTTPS://example.com/cat.png"
        ) else {
            return XCTFail("Expected .rejectedRemoteURL")
        }
    }

    // MARK: - file:// authority form

    func testFileAuthorityClassifiesAsLocalPath() {
        guard case .localPath(let path) = Send.classifyAttachment("file:///tmp/x.png") else {
            return XCTFail("Expected .localPath")
        }
        XCTAssertEqual(path, "/tmp/x.png")
    }

    // MARK: - file: short form (the regression case)

    func testFileShortFormAbsoluteClassifiesAsLocalPath() {
        // `file:/abs/path` — single-slash short form. Previously
        // accepted by `makeAttachment` and skipped by the validator.
        guard case .localPath(let path) = Send.classifyAttachment("file:/abs/path.png") else {
            return XCTFail("Expected .localPath")
        }
        XCTAssertEqual(path, "/abs/path.png")
    }

    func testFileShortFormRelativeClassifiesAsLocalPath() {
        // `file:relative/path` — no slashes after the scheme. This is
        // the exact divergence the shared classifier closes: the
        // previous validator skipped existence checking entirely
        // because `URL(string:"file:relative").isFileURL` is false.
        guard case .localPath(let path) = Send.classifyAttachment("file:relative/path.png") else {
            return XCTFail("Expected .localPath")
        }
        XCTAssertEqual(path, "relative/path.png")
    }

    // MARK: - Other scheme

    func testFTPClassifiesAsOtherScheme() {
        guard case .otherScheme(let scheme) = Send.classifyAttachment("ftp://example.com/x.png") else {
            return XCTFail("Expected .otherScheme")
        }
        XCTAssertEqual(scheme, "ftp")
    }

    func testCustomSchemeClassifiesAsOtherScheme() {
        guard case .otherScheme = Send.classifyAttachment("x-myapp://host/path") else {
            return XCTFail("Expected .otherScheme")
        }
    }

    // MARK: - Filenames containing colon

    func testColonBearingFilenameClassifiesAsLocalPath() {
        // `release:v1.png` parses with a synthetic `release` scheme,
        // but the absence of `://` means the user clearly meant a
        // filename. Pin the local-path route so this filename can be
        // attached.
        guard case .localPath(let path) = Send.classifyAttachment("release:v1.png") else {
            return XCTFail("Expected .localPath")
        }
        XCTAssertEqual(path, "release:v1.png")
    }

    // MARK: - Plain paths

    func testAbsolutePathClassifiesAsLocalPath() {
        guard case .localPath(let path) = Send.classifyAttachment("/tmp/x.png") else {
            return XCTFail("Expected .localPath")
        }
        XCTAssertEqual(path, "/tmp/x.png")
    }

    func testRelativePathClassifiesAsLocalPath() {
        guard case .localPath(let path) = Send.classifyAttachment("images/x.png") else {
            return XCTFail("Expected .localPath")
        }
        XCTAssertEqual(path, "images/x.png")
    }

    func testTildePathExpandsToHomeDir() {
        guard case .localPath(let path) = Send.classifyAttachment("~/images/x.png") else {
            return XCTFail("Expected .localPath")
        }
        // expandingTildeInPath produces the user's home dir. We don't
        // pin the exact value, only that `~` is gone.
        XCTAssertFalse(path.hasPrefix("~"), "Tilde should be expanded; got \(path)")
        XCTAssertTrue(path.hasSuffix("/images/x.png"))
    }
}
