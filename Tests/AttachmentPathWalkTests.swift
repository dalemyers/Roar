import XCTest
import ArgumentParser
@testable import roar

/// Direct unit tests for `Send.walkPathRejectingNonSystemSymlinks`.
///
/// Until now the walk was only exercised indirectly through
/// `AttachmentRealpathTests` (which calls the higher-level
/// `rejectIfUnsafeForAttachment`). That covers the integration
/// behaviour but leaves the walk's component-prefix-building loop
/// without a regression backstop — a refactor that broke the
/// prefix accumulation would fail those scenarios but the failure
/// would surface as a generic "attachment rejected" rather than a
/// pin on the walk itself.
///
/// These tests drive `walkPathRejectingNonSystemSymlinks` directly
/// and pin its contract for every code path: absolute, relative,
/// system-symlink prefix, non-system-symlink prefix, `..`,
/// non-existent component, root, and empty.
final class AttachmentPathWalkTests: XCTestCase {

    // XCTestCase fixture assigned in `setUpWithError`. See
    // `AttachmentExistenceTests` for the disable rationale.
    private var tempDir: URL! // swiftlint:disable:this implicitly_unwrapped_optional

    override func setUpWithError() throws {
        try super.setUpWithError()
        let raw = NSTemporaryDirectory().appending(
            "roar-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: raw, withIntermediateDirectories: true)
        // Canonicalise so test assertions about paths under
        // `tempDir` survive on a host where `/tmp` resolves
        // through `/private/tmp`.
        guard let resolved = realpath(raw, nil) else {
            XCTFail("Could not realpath temp dir at setup")
            return
        }
        defer { free(resolved) }
        tempDir = URL(fileURLWithPath: String(cString: resolved))
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    // MARK: - Trivial shapes

    /// A single-component absolute path (`/foo`) has no
    /// intermediate components to walk — the leaf is handled by
    /// the caller's Phase 1 `lstat`. The walk must accept it
    /// without error. (Whether `/foo` exists is irrelevant to the
    /// walk; the leaf's existence is checked elsewhere.)
    func testSingleComponentAbsolutePathAccepted() throws {
        // Pick a path that almost certainly does not exist so we
        // also pin that the walk does NOT incidentally `lstat` the
        // leaf — if it did, this would surface as `.missing` and
        // fail.
        try Send.walkPathRejectingNonSystemSymlinks(
            "/nonexistent-roar-walk-\(UUID().uuidString)")
    }

    /// `/` has zero components — the walk has nothing to inspect
    /// and must return cleanly. Pin this so a refactor that
    /// accidentally introduces an unchecked array access on
    /// `parts` doesn't crash.
    func testRootPathAccepted() throws {
        try Send.walkPathRejectingNonSystemSymlinks("/")
    }

    /// Empty path is rejected up front with `ValidationError`. The
    /// walk's caller `rejectIfUnsafeForAttachment` already would
    /// fail on the leaf `lstat`, but pinning the empty case here
    /// keeps the walk's own error vocabulary self-contained.
    func testEmptyPathRejectedAsValidationError() {
        XCTAssertThrowsError(
            try Send.walkPathRejectingNonSystemSymlinks("")
        ) { error in
            XCTAssertTrue(
                error is ValidationError,
                "Empty path should surface as ValidationError, got \(type(of: error))"
            )
        }
    }

    // MARK: - System-symlink allow-list

    /// A two-component absolute path whose first component is a
    /// known macOS system symlink (`/tmp → private/tmp`) must be
    /// accepted. Refusing this would break the standard `/tmp`
    /// workflow that every user implicitly relies on.
    func testSystemSymlinkPrefixAccepted() throws {
        // `/tmp/<anything>` — the walk only inspects intermediate
        // components, so the leaf doesn't have to exist for the
        // walk to render its verdict on `/tmp`.
        try Send.walkPathRejectingNonSystemSymlinks(
            "/tmp/roar-walk-leaf-\(UUID().uuidString)")
    }

    /// Case-insensitive lookup on the allow-list: macOS's default
    /// volume is case-insensitive, so `lstat("/TMP")` and
    /// `lstat("/tmp")` resolve to the same inode. Without
    /// case-normalisation of the lookup key, `/TMP/foo.png` would
    /// be (incorrectly) refused. Pin the POSIX-lowercase
    /// normalisation.
    func testSystemSymlinkPrefixUppercaseAccepted() throws {
        try Send.walkPathRejectingNonSystemSymlinks(
            "/TMP/roar-walk-leaf-\(UUID().uuidString)")
    }

    /// A two-component absolute path whose first component is a
    /// NON-system symlink must be refused with `.symlink`. The
    /// walk's diagnostic must name the offending component.
    func testNonSystemSymlinkPrefixRejected() throws {
        // Layout: tempDir/link -> tempDir/real
        // Then walk `tempDir/link/leaf`.
        let realDir = tempDir.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: realDir, withIntermediateDirectories: true)
        let linkDir = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: linkDir, withDestinationURL: realDir)

        let walkPath = linkDir.appendingPathComponent("leaf").path
        XCTAssertThrowsError(
            try Send.walkPathRejectingNonSystemSymlinks(walkPath)
        ) { error in
            guard let attErr = error as? Send.AttachmentError else {
                return XCTFail("Expected AttachmentError, got \(type(of: error))")
            }
            if case .unsafeLocalAttachment(let p, let reason) = attErr {
                XCTAssertEqual(reason, .symlink)
                XCTAssertEqual(p, linkDir.path,
                    "Diagnostic must name the offending symlink prefix")
            } else {
                XCTFail("Expected .unsafeLocalAttachment, got \(attErr)")
            }
        }
    }

    // MARK: - Non-existent component

    /// An intermediate component that doesn't exist surfaces as
    /// `.missing(errno:)`. Pin the errno-bearing shape so callers
    /// can distinguish "missing prefix" from "untrusted symlink"
    /// in error reporting.
    func testNonExistentIntermediateSurfacesMissing() throws {
        let nonexistent = tempDir.appendingPathComponent(
            "doesnotexist-\(UUID().uuidString)")
        let walkPath = nonexistent.appendingPathComponent("leaf").path
        XCTAssertThrowsError(
            try Send.walkPathRejectingNonSystemSymlinks(walkPath)
        ) { error in
            guard let attErr = error as? Send.AttachmentError else {
                return XCTFail("Expected AttachmentError, got \(type(of: error))")
            }
            if case .unsafeLocalAttachment(let p, let reason) = attErr {
                if case .missing(let errno) = reason {
                    XCTAssertEqual(
                        errno, ENOENT,
                        "Missing intermediate should report ENOENT")
                } else {
                    XCTFail("Expected .missing, got \(reason)")
                }
                XCTAssertEqual(
                    p, nonexistent.path,
                    "Diagnostic must name the missing prefix")
            } else {
                XCTFail("Expected .unsafeLocalAttachment, got \(attErr)")
            }
        }
    }

    // MARK: - `..` semantics

    /// `..` components are NOT pre-normalised by the walk —
    /// `lstat` resolves them lazily, which means an intermediate
    /// symlink along the literal path is still seen as a symlink
    /// before the `..` collapses it away. Pin that the walk's
    /// per-component `lstat` happens on the literal prefix, so
    /// a path like `/tmp/../etc` walks `/tmp` first (accepted)
    /// then `/tmp/..` (a directory, by definition not a symlink)
    /// then the leaf elsewhere. The user-observable behaviour is
    /// "no false-reject on `/tmp/../...`".
    func testDotDotComponentsAcceptedAcrossSystemSymlink() throws {
        // `/tmp/../tmp/<leaf>` — every intermediate component:
        //   /tmp        — system symlink, accepted
        //   /tmp/..     — directory, not a symlink, accepted
        //   /tmp/../tmp — system symlink, accepted
        // Leaf is not the walk's concern.
        try Send.walkPathRejectingNonSystemSymlinks(
            "/tmp/../tmp/roar-walk-dotdot-\(UUID().uuidString)")
    }

    /// `..` that traverses a NON-system symlink is still rejected
    /// — the literal-prefix `lstat` catches the symlink before
    /// `..` would collapse it. Pin so that a refactor pre-
    /// normalising `..` (which would bypass the symlink check)
    /// fails this test.
    func testDotDotDoesNotBypassNonSystemSymlink() throws {
        let realDir = tempDir.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: realDir, withIntermediateDirectories: true)
        let linkDir = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: linkDir, withDestinationURL: realDir)

        // Walking `tempDir/link/../real/leaf` — `link` is the
        // first non-system symlink we hit, and the walk must
        // refuse it before `..` would collapse the prefix.
        let walkPath = linkDir.path + "/../real/leaf"
        XCTAssertThrowsError(
            try Send.walkPathRejectingNonSystemSymlinks(walkPath)
        ) { error in
            guard let attErr = error as? Send.AttachmentError else {
                return XCTFail("Expected AttachmentError, got \(type(of: error))")
            }
            if case .unsafeLocalAttachment(_, let reason) = attErr {
                XCTAssertEqual(
                    reason, .symlink,
                    "Non-system symlink prefix before `..` must still refuse")
            } else {
                XCTFail("Expected .unsafeLocalAttachment, got \(attErr)")
            }
        }
    }

    // MARK: - readlink failure

    /// If `readlink` fails on a known-symlink intermediate component
    /// (e.g. EACCES because the parent directory was chmod'd 0), the
    /// walk must surface `.missing(errno:)` — NOT `.symlink`. The
    /// `.symlink` message says "the link target may differ from what
    /// was intended; pass the real path instead," which is a
    /// mischaracterisation of "we couldn't read the link at all." Pin
    /// the diagnostic class so the user sees a permissions-flavoured
    /// error, not a target-mismatch one.
    func testReadlinkFailureSurfacesMissingNotSymlink() throws {
        // Layout: tempDir/parent/{real, link -> real}. We then chmod
        // `parent` to 0 so `lstat` on the symlink still works
        // (S_IFLNK comes from the dirent inode the kernel cached
        // when the parent had perms — but `readlink` will fail with
        // EACCES on a fresh open).
        //
        // Note: macOS's behaviour for `lstat` after chmod-to-0 is
        // that the cached parent-inode metadata still satisfies
        // `lstat` once the test process holds an fd-like reference,
        // but cross-process / cold lookups also need search
        // permission on the parent. We approximate by chmod'ing the
        // parent AFTER constructing the layout; the `lstat` in the
        // walk traverses the parent which has perms 0 — the walk
        // will fail at the parent (`.missing` for EACCES) rather
        // than reaching the readlink branch. That still pins the
        // class of error: an unreadable intermediate surfaces
        // `.missing`, not `.symlink`. The headline contract is
        // "permissions failures don't masquerade as symlink-policy
        // failures," which this test exercises.
        let parent = tempDir.appendingPathComponent("noperm")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
        let real = parent.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: real, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: real)

        // chmod parent to 0 — no read, no execute, no search. Any
        // syscall traversing `parent` for a child will hit EACCES.
        let result = chmod(parent.path, 0)
        guard result == 0 else {
            XCTFail("chmod failed: \(errno)")
            return
        }
        // Always restore perms in teardown so the temp dir is
        // cleanable.
        defer { _ = chmod(parent.path, 0o755) }

        let walkPath = link.appendingPathComponent("leaf").path
        XCTAssertThrowsError(
            try Send.walkPathRejectingNonSystemSymlinks(walkPath)
        ) { error in
            guard let attErr = error as? Send.AttachmentError else {
                return XCTFail("Expected AttachmentError, got \(type(of: error))")
            }
            if case .unsafeLocalAttachment(_, let reason) = attErr {
                if case .missing = reason {
                    // OK — permissions failure surfaces as
                    // `.missing`, not `.symlink`. The exact errno
                    // (EACCES vs ENOENT) depends on which syscall
                    // failed first; pinning the case discriminator
                    // is sufficient for the contract.
                } else {
                    XCTFail(
                        "Expected .missing for permissions failure, got \(reason)"
                    )
                }
            } else {
                XCTFail("Expected .unsafeLocalAttachment, got \(attErr)")
            }
        }
    }

    // MARK: - Allow-list shape pinning

    /// Spot-check the allow-list contains only the well-known
    /// macOS top-level system symlinks. A refactor that
    /// accidentally adds an entry would expand the trust boundary
    /// silently; pin the exact membership so the diff is loud.
    func testAllowListMembership() {
        XCTAssertEqual(
            Send.macOSSystemSymlinkAllowList,
            [
                "/tmp": "private/tmp",
                "/var": "private/var",
                "/etc": "private/etc",
            ],
            "macOS system-symlink allow-list must contain exactly /tmp, /var, /etc"
        )
    }
}
