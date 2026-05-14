import XCTest
import ArgumentParser
@testable import roar

/// Pin that `--attachment` rejects http/https URLs at validation
/// with a clear "use curl first" diagnostic. The remote-fetch path
/// was deleted (URLSession SSRF screening, redirect guard, size
/// cap, etc.); users who want to attach a URL pre-download it with
/// `curl -o /tmp/foo.png URL` and pass the resulting path. The
/// validator must surface that guidance up front so the user
/// doesn't rediscover the deletion through an opaque downstream
/// error.
final class AttachmentRemoteRejectedTests: XCTestCase {

    func testHTTPSRejectedAtValidation() {
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal("https://example.com/cat.png")
        ) { error in
            XCTAssertTrue(error is ValidationError, "got \(type(of: error))")
        }
    }

    func testHTTPRejectedAtValidation() {
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal("http://example.com/cat.png")
        ) { error in
            XCTAssertTrue(error is ValidationError, "got \(type(of: error))")
        }
    }

    func testHTTPSErrorMentionsCurl() {
        // The error must mention `curl` so the user immediately
        // knows the supported workaround. Without this guidance the
        // deletion of the remote-fetch path would surface as an
        // unhelpful "URL scheme not supported" with no actionable
        // next step.
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal("https://example.com/cat.png")
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("curl"),
                "Error should mention curl; got: \(message)"
            )
        }
    }

    func testHTTPErrorMentionsCurl() {
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal("http://example.com/cat.png")
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("curl"),
                "Error should mention curl; got: \(message)"
            )
        }
    }

    func testUppercaseHTTPSAlsoRejected() {
        // The classifier folds the scheme with POSIX-locale
        // lowercasing before checking the rejected-remote set, so
        // `HTTPS://...` must take the same path as `https://...`. A
        // regression that swapped the fold to plain `.lowercased()`
        // would still reject this case on a typical en_US locale —
        // the test pins behaviour, not the locale defence (which is
        // covered by AttachmentPathTests' Turkish-locale check).
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal("HTTPS://example.com/cat.png")
        ) { error in
            XCTAssertTrue(error is ValidationError, "got \(type(of: error))")
        }
    }

    /// The thrown ValidationError text echoes the user's URL so
    /// they can copy-paste it into the suggested `curl -o /tmp/file 'URL'`
    /// invocation. Pin that the URL appears in the diagnostic.
    func testErrorIncludesUserURL() {
        let url = "https://example.com/specific-path-12345.png"
        XCTAssertThrowsError(
            try Send.validateAttachmentExistsIfLocal(url)
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains(url),
                "Error should echo the input URL; got: \(message)"
            )
        }
    }
}
