import XCTest
import ArgumentParser
@testable import roar

/// Pin the `realpath(3)` canonicalisation `rejectIfUnsafeForAttachment`
/// applies before handing a path to `UNNotificationAttachment`.
///
/// The pre-existing leaf-symlink rejection (covered by
/// `AttachmentSymlinkTests`) only inspects the final component
/// via `lstat`. A path like `/tmp/safedir/file.png` where
/// `/tmp/safedir` is itself a symlink to a privileged directory
/// would pass that check (file.png is a regular file at the
/// resolved target) and silently attach the privileged file.
/// The `realpath` upgrade closes that gap by resolving every
/// intermediate component before the second lstat, and returns
/// the canonical path so callers hand UN what was actually
/// validated rather than the input string the kernel will then
/// re-resolve.
final class AttachmentRealpathTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Register the raw path *first* so `tearDownWithError`
        // can still clean it up if `realpath` below fails — without
        // that the teardown would crash on the implicit-unwrap
        // and obscure the actual setup failure.
        let raw = NSTemporaryDirectory().appending("roar-realpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: raw, withIntermediateDirectories: true)
        tempDir = URL(fileURLWithPath: raw)
        // Use `realpath` on the temp dir itself — macOS's
        // `/tmp` is a symlink to `/private/tmp`, and we want the
        // canonical form so assertions about canonical-path
        // equality below survive on the real test host.
        guard let resolved = realpath(raw, nil) else {
            XCTFail("Could not realpath temp dir at setup")
            return
        }
        defer { free(resolved) }
        tempDir = URL(fileURLWithPath: String(cString: resolved))
    }

    override func tearDownWithError() throws {
        // Defensive nil-guard: if `setUpWithError` failed before
        // `tempDir` was assigned, unwrapping it here would crash
        // and obscure the actual setup failure.
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    /// A regular file under a regular directory passes and returns
    /// its own path. Sanity check that the realpath upgrade doesn't
    /// break the common case.
    func testRegularFileReturnsItsOwnPath() throws {
        let file = tempDir.appendingPathComponent("real.png")
        try Data().write(to: file)
        let canonical = try Send.rejectIfUnsafeForAttachment(path: file.path)
        XCTAssertEqual(canonical, file.path,
                       "Regular file under regular directory should canonicalise to itself")
    }

    /// Pre-staged intermediate-symlink attack: an attacker drops
    /// `/tmp/<test>/linkdir → /tmp/<test>/realdir` and stores a
    /// file under the symlink. The bare-`realpath` check would
    /// accept this (the canonical path is a regular file under a
    /// real directory the user "could" have typed), but the user's
    /// mental model of `/tmp/<test>/linkdir/file.png` doesn't
    /// account for `linkdir` being attacker-controllable. The
    /// per-component walk in `rejectIfUnsafeForAttachment` refuses
    /// any non-system symlink in the path, closing the gap.
    ///
    /// (In a real attack, `linkdir` would point at e.g.
    /// `/Users/victim/Library/Mail/`; modelling that here requires
    /// privileged setup, so the test substitutes a local target.
    /// The rejection rule is target-independent — any non-system
    /// symlink fails — so the local target faithfully exercises
    /// the gate.)
    func testIntermediateSymlinkIsRejected() throws {
        let realDir = tempDir.appendingPathComponent("realdir")
        try FileManager.default.createDirectory(
            at: realDir, withIntermediateDirectories: true)
        let file = realDir.appendingPathComponent("file.png")
        try Data().write(to: file)

        let linkDir = tempDir.appendingPathComponent("linkdir")
        try FileManager.default.createSymbolicLink(
            at: linkDir, withDestinationURL: realDir)
        let accessed = linkDir.appendingPathComponent("file.png")

        XCTAssertThrowsError(
            try Send.rejectIfUnsafeForAttachment(path: accessed.path)
        ) { error in
            guard let attErr = error as? Send.AttachmentError else {
                return XCTFail("Expected AttachmentError, got \(type(of: error))")
            }
            if case .unsafeLocalAttachment(let p, let reason) = attErr {
                XCTAssertEqual(
                    reason, .symlink,
                    "Intermediate non-system symlink must be refused"
                )
                XCTAssertTrue(
                    p.contains("/linkdir"),
                    "Error must name the offending symlink (got \(p))"
                )
            } else {
                XCTFail("Expected .unsafeLocalAttachment, got \(attErr)")
            }
        }
    }

    /// macOS's `/tmp` is a system symlink to `/private/tmp`. Every
    /// user (and every tool a user might `--attachment`) crosses
    /// this without noticing, so the walk must transparently
    /// accept it — refusing it outright would break the standard
    /// `/tmp` workflow that the original
    /// `rejectIfUnsafeForAttachment` design preserved.
    ///
    /// Implementation note: the temp file is placed *directly* in
    /// `/tmp`, not in a fresh test-owned subdirectory, so the path
    /// crosses the `/tmp → /private/tmp` system symlink. The
    /// fixture is removed in the cleanup block; if the test fails
    /// the file is left behind under a UUID-prefixed name, which
    /// the system reaper sweeps periodically.
    func testSystemSymlinkTransparentlyAccepted() throws {
        let leaf = "/tmp/roar-realpath-tmpcheck-\(UUID().uuidString).png"
        FileManager.default.createFile(atPath: leaf, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: leaf) }
        let canonical = try Send.rejectIfUnsafeForAttachment(path: leaf)
        // `/tmp` resolves through the system symlink to
        // `/private/tmp`. The user-supplied path was `/tmp/...`
        // (system symlink), so the canonical form must end up
        // under `/private/tmp/...`.
        XCTAssertTrue(
            canonical.hasPrefix("/private/tmp/"),
            "macOS /tmp is a system symlink to /private/tmp; got \(canonical)"
        )
    }

    /// A file directly under a non-system-symlink directory (the
    /// common case — every attachment that lives under the user's
    /// home / a project tree / a freshly-created temp subdirectory)
    /// must continue to pass. This is the regression backstop for
    /// the walk: a too-aggressive symlink check would reject
    /// everything that crosses any system symlink and break every
    /// real `--attachment` invocation.
    func testRegularDirectoryStillAccepted() throws {
        let realDir = tempDir.appendingPathComponent("realdir")
        try FileManager.default.createDirectory(
            at: realDir, withIntermediateDirectories: true)
        let file = realDir.appendingPathComponent("file.png")
        try Data().write(to: file)
        let canonical = try Send.rejectIfUnsafeForAttachment(path: file.path)
        // The canonical form should reflect the real on-disk
        // location. `tempDir` was already canonicalised in setUp,
        // so the canonical path should start with that prefix.
        XCTAssertTrue(
            canonical.hasPrefix(tempDir.path),
            "Regular file under canonical temp dir should pass; got \(canonical)"
        )
    }

    /// Symlink AT THE LEAF is still rejected — `realpath` would
    /// resolve it to a regular file and pass the canonical-path
    /// lstat, but the Phase 1 leaf `lstat` on the user-supplied
    /// path catches it first. Pin the contract: even though the
    /// target is a regular file, a leaf symlink is refused so the
    /// user sees the diagnostic naming the link.
    func testLeafSymlinkStillRejected() throws {
        let target = tempDir.appendingPathComponent("target.png")
        try Data().write(to: target)
        let link = tempDir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: target)
        XCTAssertThrowsError(
            try Send.rejectIfUnsafeForAttachment(path: link.path)
        ) { error in
            guard let attErr = error as? Send.AttachmentError else {
                return XCTFail("Expected AttachmentError, got \(type(of: error))")
            }
            if case .unsafeLocalAttachment(_, let reason) = attErr {
                XCTAssertEqual(reason, .symlink,
                               "Leaf symlink must be rejected even if target is a regular file")
            } else {
                XCTFail("Expected .unsafeLocalAttachment, got \(attErr)")
            }
        }
    }

    /// Result is discardable — existing callers in the test suite
    /// (which use `try ... rejectIfUnsafeForAttachment(...)` without
    /// assigning the return) should still compile and pass without
    /// warning. Pin the `@discardableResult` annotation so a future
    /// refactor doesn't quietly remove it and trigger
    /// `-Wunused-result` everywhere.
    func testDiscardableResultDoesNotWarn() throws {
        let file = tempDir.appendingPathComponent("ok.png")
        try Data().write(to: file)
        // No `let _ =` — relying on `@discardableResult`. If the
        // annotation goes away this file will fail to compile in
        // warnings-as-errors mode, which is the regression we want.
        try Send.rejectIfUnsafeForAttachment(path: file.path)
    }

    // MARK: - Relative paths under a non-system-symlink cwd
    //
    // The walk's purpose is to defend against attacker-typed paths
    // whose intermediate components are attacker-staged symlinks.
    // The cwd, however, is shell-chosen — a user `cd`-ed into a
    // directory reachable only via a non-system symlink (a common
    // setup on dev machines that mount an external volume into
    // `/Users/me/dev`) has typed nothing attacker-controllable.
    // Refusing such paths would be a workflow break with no
    // security upside, so the walk canonicalises the cwd before
    // joining it with the user-typed remainder. These tests pin
    // that behaviour.

    /// Relative attachment path whose cwd is reachable only
    /// through a non-system symlink must still be accepted —
    /// the cwd is a trusted reference frame.
    func testRelativePathUnderSymlinkedCwdAccepted() throws {
        // Build:
        //   tempDir/real-cwd/foo.png         (the real target)
        //   tempDir/link-cwd -> tempDir/real-cwd
        // Then `cd link-cwd && roar send --attachment foo.png`.
        // The relative path is `foo.png`; the cwd resolves through
        // `link-cwd`, which is a non-system symlink. Pre-fix this
        // would have been rejected. Post-fix the cwd is
        // canonicalised before the walk, so the user-typed
        // remainder (`foo.png`) is the only thing the strict
        // policy applies to.
        let realCwd = tempDir.appendingPathComponent("real-cwd")
        try FileManager.default.createDirectory(
            at: realCwd, withIntermediateDirectories: true)
        let file = realCwd.appendingPathComponent("foo.png")
        try Data().write(to: file)
        let linkCwd = tempDir.appendingPathComponent("link-cwd")
        try FileManager.default.createSymbolicLink(
            at: linkCwd, withDestinationURL: realCwd)

        // Save and restore cwd via `defer` so other tests in the
        // suite aren't affected if this one fails mid-way.
        let originalCwd = FileManager.default.currentDirectoryPath
        defer {
            _ = FileManager.default.changeCurrentDirectoryPath(originalCwd)
        }
        XCTAssertTrue(
            FileManager.default.changeCurrentDirectoryPath(linkCwd.path),
            "Could not chdir into symlinked cwd"
        )

        // Relative path — the input the user actually typed.
        let canonical = try Send.rejectIfUnsafeForAttachment(path: "foo.png")
        // Canonical form lands under the *real* cwd (the symlink
        // resolved). The exact prefix is `tempDir/real-cwd`.
        XCTAssertTrue(
            canonical.hasPrefix(realCwd.path),
            "Canonical form must resolve through the symlinked "
            + "cwd to the real on-disk location; got \(canonical)"
        )
    }

    /// A non-system symlink in the USER-TYPED portion of a
    /// relative path is still refused. The cwd canonicalisation
    /// must not bleed permissiveness into components the user
    /// actually typed.
    func testRelativePathWithSymlinkInUserTypedPortionRejected() throws {
        // Layout:
        //   tempDir/cwd/real/bar.png      (the real target)
        //   tempDir/cwd/sneaky -> tempDir/cwd/real
        // Then `cd cwd && roar send --attachment sneaky/bar.png`.
        // `sneaky` is in the USER-TYPED part of the input — it
        // must be refused even though the cwd itself is fine.
        let cwd = tempDir.appendingPathComponent("cwd")
        try FileManager.default.createDirectory(
            at: cwd, withIntermediateDirectories: true)
        let realSub = cwd.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: realSub, withIntermediateDirectories: true)
        let file = realSub.appendingPathComponent("bar.png")
        try Data().write(to: file)
        let sneakySub = cwd.appendingPathComponent("sneaky")
        try FileManager.default.createSymbolicLink(
            at: sneakySub, withDestinationURL: realSub)

        let originalCwd = FileManager.default.currentDirectoryPath
        defer {
            _ = FileManager.default.changeCurrentDirectoryPath(originalCwd)
        }
        XCTAssertTrue(
            FileManager.default.changeCurrentDirectoryPath(cwd.path),
            "Could not chdir to test cwd"
        )

        XCTAssertThrowsError(
            try Send.rejectIfUnsafeForAttachment(path: "sneaky/bar.png")
        ) { error in
            guard let attErr = error as? Send.AttachmentError else {
                return XCTFail("Expected AttachmentError, got \(type(of: error))")
            }
            if case .unsafeLocalAttachment(let p, let reason) = attErr {
                XCTAssertEqual(
                    reason, .symlink,
                    "Symlink in user-typed portion must be refused"
                )
                XCTAssertTrue(
                    p.contains("/sneaky"),
                    "Error must name the user-typed symlink (got \(p))"
                )
            } else {
                XCTFail("Expected .unsafeLocalAttachment, got \(attErr)")
            }
        }
    }
}
