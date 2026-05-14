import XCTest
import ArgumentParser
@testable import roar

/// Pin the per-notification attachment count cap, the entry point
/// where the singular-vs-plural flag distinction lands. The
/// validators that run on each individual path (existence, symlink,
/// scheme) are already covered by AttachmentPathTests /
/// AttachmentExistenceTests / AttachmentSymlinkTests; this file
/// only checks the array-aware glue layer.
final class AttachmentMultipleTests: XCTestCase {

    func testEmptyAttachmentListAllowed() throws {
        // No `--attachment` at all is the common case for plain text
        // notifications. The count validator must accept it.
        try Send.validateAttachmentCount([])
    }

    func testOneAttachmentAllowed() throws {
        try Send.validateAttachmentCount(["/tmp/single.png"])
    }

    func testMultipleUnderLimitAllowed() throws {
        let list = ["/tmp/a.png", "/tmp/b.png", "/tmp/c.mp4"]
        XCTAssertLessThan(list.count, Send.maximumAttachmentCount)
        try Send.validateAttachmentCount(list)
    }

    func testExactlyAtLimitAllowed() throws {
        // The boundary itself is inclusive — the cap is "no more
        // than", not "fewer than". A user posting exactly the
        // documented maximum should not be punished for hitting the
        // round number.
        let list = (0..<Send.maximumAttachmentCount).map { "/tmp/\($0).png" }
        try Send.validateAttachmentCount(list)
    }

    func testOverLimitRejected() {
        let list = (0...Send.maximumAttachmentCount).map { "/tmp/\($0).png" }
        XCTAssertThrowsError(try Send.validateAttachmentCount(list)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }
}
