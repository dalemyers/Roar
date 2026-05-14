import XCTest
import ArgumentParser
@testable import roar

/// Pin the userInfo size validator. Property-list `binary` is the
/// serialization shape UN's XPC bridge uses internally, so the
/// measurement here matches the framework's view rather than
/// the `xml` form's 2–5× inflation.
final class UserInfoSizeTests: XCTestCase {

    func testEmptyAccepted() throws {
        // The plain `roar send --body x` case: no flags that
        // contribute to userInfo, dictionary is empty.
        try Send.validateUserInfoSize([:])
    }

    func testSmallAccepted() throws {
        let userInfo: [String: String] = [
            "roar.activate.bundleID": "com.apple.Safari",
            "roar.open.url": "https://example.com",
            "roar.open.allowedSchemes": "http,https,mailto",
        ]
        try Send.validateUserInfoSize(userInfo)
    }

    func testJustUnderCapAccepted() throws {
        // Construct a single value whose serialized size sits
        // comfortably under the cap. Property-list binary adds
        // ~80–100 bytes of frame / object-table / offset-table
        // overhead around the entry, so we subtract a generous
        // margin (1 KB) to stay below the cap regardless of the
        // exact bplist encoding choices made by Foundation.
        let margin = 1024
        let valueLength = Send.maximumUserInfoSize - margin
        let userInfo: [String: String] = [
            "roar.exec.command": String(repeating: "a", count: valueLength),
        ]
        try Send.validateUserInfoSize(userInfo)
    }

    func testOverCapRejected() {
        // Over the cap by a wide margin so framing overhead can't
        // accidentally pull this back under.
        let userInfo: [String: String] = [
            "roar.exec.command":
                String(repeating: "x", count: Send.maximumUserInfoSize + 1024),
        ]
        XCTAssertThrowsError(try Send.validateUserInfoSize(userInfo)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testCapIsBinarySerialization() throws {
        // The cap is measured against `binary` plist, not `xml`. A
        // value sized at ~10 KB serializes near 10 KB in binary but
        // expands to ~25–30 KB in xml. If the validator were
        // accidentally measuring xml, this would reject; binary
        // accepts.
        let valueLength = 10 * 1024
        let userInfo: [String: String] = [
            "roar.exec.command": String(repeating: "a", count: valueLength),
        ]
        try Send.validateUserInfoSize(userInfo)
    }

    // MARK: - buildUserInfo

    /// `buildUserInfo` is the extracted constructor that `run()` calls
    /// *before* draining stdin. Pin its contract here: the dictionary
    /// it produces depends only on flag values, never on the body or
    /// the attachments. That property is load-bearing for fix #8 —
    /// the size check fires fast on a pathological `--exec` even if
    /// the user also piped a 1 MB body, because we never read the
    /// pipe before constructing/validating userInfo.
    func testBuildUserInfoEmptyWhenNoFlags() {
        let userInfo = Send.buildUserInfo(
            activateBundleID: nil,
            exec: nil,
            resolvedOpenURL: nil,
            openUrlAllowList: nil,
            resolvedForegroundPresentation: nil
        )
        XCTAssertTrue(userInfo.isEmpty)
    }

    func testBuildUserInfoIncludesActivateBundleID() {
        let userInfo = Send.buildUserInfo(
            activateBundleID: "com.apple.Safari",
            exec: nil,
            resolvedOpenURL: nil,
            openUrlAllowList: nil,
            resolvedForegroundPresentation: nil
        )
        XCTAssertEqual(userInfo["roar.activate.bundleID"], "com.apple.Safari")
    }

    func testBuildUserInfoIncludesExecAndConsent() {
        let userInfo = Send.buildUserInfo(
            activateBundleID: nil,
            exec: "echo hi",
            resolvedOpenURL: nil,
            openUrlAllowList: nil,
            resolvedForegroundPresentation: nil
        )
        XCTAssertEqual(userInfo["roar.exec.command"], "echo hi")
        // Consent key must be set whenever the command key is — the
        // RoarAppDelegate side gates execution on this pair.
        XCTAssertEqual(userInfo["roar.exec.consent"], "1")
    }

    /// When the caller passes `nil` for `openUrlAllowList`,
    /// `buildUserInfo` serialises `defaultOpenSchemes` so the
    /// click-time re-parse has a concrete allow-list to validate
    /// against. Empty / missing would silently fall back to "no
    /// allow-list" at the click side; the explicit serialisation
    /// pins the contract.
    func testBuildUserInfoIncludesDefaultAllowListWhenNoAdditions() {
        let userInfo = Send.buildUserInfo(
            activateBundleID: nil,
            exec: nil,
            resolvedOpenURL: "https://example.com",
            openUrlAllowList: nil,
            resolvedForegroundPresentation: nil
        )
        XCTAssertEqual(userInfo["roar.open.url"], "https://example.com")
        let serialised = userInfo["roar.open.allowedSchemes"] ?? ""
        let restored = URLValidation.deserializeAllowList(serialised)
        XCTAssertEqual(restored, URLValidation.defaultOpenSchemes)
    }

    /// When the caller passes a non-nil allow-list (the normal path
    /// — `Send.run` computes one via `buildAllowList`),
    /// `buildUserInfo` serialises the exact set so the click handler
    /// can validate against the same set.
    func testBuildUserInfoSerialisesUserAdditions() {
        let allowList: Set<String> = ["http", "https", "mailto", "ssh"]
        let userInfo = Send.buildUserInfo(
            activateBundleID: nil,
            exec: nil,
            resolvedOpenURL: "ssh://host",
            openUrlAllowList: allowList,
            resolvedForegroundPresentation: nil
        )
        let serialised = userInfo["roar.open.allowedSchemes"] ?? ""
        let restored = URLValidation.deserializeAllowList(serialised)
        XCTAssertEqual(restored, allowList)
    }

    /// Pin the fast-fail ordering for fix #8: an oversized `--exec`
    /// value must trip the size validator on the *flag-derived*
    /// dictionary alone, with no body / attachment / stdin
    /// involvement. The previous implementation built userInfo only
    /// after `resolveBody()` had drained up to 1 MB from stdin, so a
    /// piped-body-plus-oversized-exec invocation would read the
    /// whole pipe and then reject — wasting the read.
    ///
    /// We can't easily prove "stdin was not consumed" from a unit
    /// test (XCTest doesn't isolate stdin per-test), but we *can*
    /// pin that `buildUserInfo` + `validateUserInfoSize` together
    /// reject a pathological `--exec` in pure-flag space, without
    /// needing any other call. That's the contract `run()` now
    /// relies on for the hoist to be sound.
    func testBuildUserInfoSizeCheckRejectsOversizedExec() {
        // 2× the cap so framing overhead can't pull this back under.
        let exec = String(repeating: "x", count: 2 * Send.maximumUserInfoSize)
        let userInfo = Send.buildUserInfo(
            activateBundleID: nil,
            exec: exec,
            resolvedOpenURL: nil,
            openUrlAllowList: nil,
            resolvedForegroundPresentation: nil
        )
        XCTAssertThrowsError(try Send.validateUserInfoSize(userInfo)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }
}
