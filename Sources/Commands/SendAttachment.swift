import ArgumentParser
import Foundation
import os
import UniformTypeIdentifiers
import UserNotifications

// All attachment-handling code for `roar send` lives in
// this extension. It was split out of `Send.swift` once the file
// crossed 800 lines and the local-attachment hardening (symlink
// rejection, intermediate-component walk, canonical-path
// resolution) had its own substantial test surface. Tests refer to
// these as `Send.AttachmentError` and `Send.AttachmentFetchError`;
// keeping everything nested under `Send` via this extension preserves
// those references unchanged.
//
// `--attachment` accepts LOCAL paths only. Users who want to attach
// a remote URL pre-download it with `curl -o /tmp/foo.png URL` and
// pass the local path. The previous remote-fetch path (URLSession,
// SSRF screening, size cap, redirect guard, etc.) was deleted —
// keeping it required maintaining an HTTP client inside a CLI tool
// that the user can replace with one `curl` invocation.
extension Send {

    /// Build the `options` dictionary handed to `UNNotificationAttachment.init`.
    /// Returns `nil` if the user passed no attachment-shaping flags so
    /// we preserve the framework's default behaviour (one less `[:]`
    /// round trip and avoids the rare case where an empty options dict
    /// behaves differently from `nil`).
    ///
    /// - Parameters:
    ///   - noThumbnail: The `--no-thumbnail` flag value.
    ///   - thumbnailTime: The `--thumbnail-time` value (already
    ///     validated non-negative finite or `nil`).
    ///   - typeHint: The `--attachment-type-hint` value (already
    ///     validated non-empty or `nil`). When set, the framework uses
    ///     this UTI instead of inferring from the filename extension —
    ///     useful for local files whose extension is misleading.
    /// - Returns: The options dict to hand to UN, or `nil` if no flag
    ///   was set.
    static func buildAttachmentOptions(
        noThumbnail: Bool,
        thumbnailTime: Double?,
        typeHint: String? = nil
    ) -> [String: Any]? {
        var options: [String: Any] = [:]
        if noThumbnail {
            options[UNNotificationAttachmentOptionsThumbnailHiddenKey] = true
        }
        if let thumbnailTime {
            // The key accepts either an NSValue-wrapped CMTime or an
            // NSNumber of seconds; the NSNumber form is the simpler
            // shape and matches how Apple's own examples write it.
            options[UNNotificationAttachmentOptionsThumbnailTimeKey] =
                NSNumber(value: thumbnailTime)
        }
        if let typeHint {
            // The framework documents this key as "the UTI of the
            // attachment." Reverse-DNS dotted UTIs ("public.png") and
            // dynamic UTIs ("dyn.…") are both accepted. We pass the
            // string through verbatim — validation already screened
            // for emptiness; UTI parsing is the framework's job.
            options[UNNotificationAttachmentOptionsTypeHintKey] = typeHint
        }
        return options.isEmpty ? nil : options
    }

    /// Schemes treated as "the user typed a remote URL" — rejected
    /// at validation with guidance to pre-download with `curl`.
    /// `--attachment` does not fetch over the network; the previous
    /// fetch path is gone.
    static let attachmentRejectedRemoteSchemes: Set<String> = ["http", "https"]

    /// Bucketing of an `--attachment` value into the path the rest of
    /// the attachment pipeline will take. Computed once by
    /// `classifyAttachment` and consumed by both
    /// `validateAttachmentExistsIfLocal` (send-time existence /
    /// symlink check) and `makeAttachment` (the actual load), so a
    /// value cannot be routed one way at validation and a different
    /// way at construction. The previous arrangement had two separate
    /// `URL(string:).isFileURL`-style classifiers that disagreed on
    /// `file:relative/path` (no slashes after the scheme): the
    /// validator skipped existence checking entirely while
    /// `makeAttachment` happily handed the malformed URL to
    /// `UNNotificationAttachment.init`, producing an opaque
    /// "couldn't be opened" error.
    enum AttachmentSource: Equatable {
        /// Local filesystem path (`~` already expanded; symlinks NOT
        /// yet resolved — that's the caller's job, see
        /// `rejectIfUnsafeForAttachment`). Covers plain paths, `file://`
        /// authority-form URLs, and `file:`-short-form URLs.
        case localPath(String)
        /// User passed an http/https URL. `--attachment` no longer
        /// fetches remote URLs; the validator surfaces a clear error
        /// telling the user to pre-download with `curl` and pass the
        /// resulting local path.
        case rejectedRemoteURL(scheme: String)
        /// Some other URL scheme (`ftp://`, `data:`, custom handler,
        /// etc.). `makeAttachment` produces a `disallowedScheme` error;
        /// the validator treats it as "downstream's problem" and
        /// returns clean.
        case otherScheme(String)
    }

    /// Decide which code path an `--attachment` value falls into.
    ///
    /// Classification rules (must match both call sites):
    ///
    ///   * `http://...` or `https://...` — `.rejectedRemoteURL`. The
    ///     validator surfaces a "use curl" error before reaching
    ///     `makeAttachment`.
    ///   * `file:` (any form, including `file:///abs`, `file:/abs`, and
    ///     `file:rel`) — `.localPath` containing the percent-decoded
    ///     path. `file://hostname/x` is rejected upstream by
    ///     `validateAttachmentPath` before reaching this function.
    ///   * `someother://...` — `.otherScheme`. `makeAttachment`
    ///     surfaces a friendlier error than `UNNotificationAttachment.init`
    ///     would.
    ///   * Anything without `://` *and* without an explicit `file:`
    ///     prefix — `.localPath`. This catches filenames containing a
    ///     colon (`release:v1.png`) which `URL(string:)` would
    ///     otherwise parse with a bogus scheme.
    ///
    /// - Parameter pathOrURL: The user-supplied `--attachment`
    ///   value.
    /// - Returns: The classification bucket. The `.localPath`
    ///   associated value has `~` expanded but is NOT yet checked for
    ///   existence or symlink-ness.
    /// Refuse a decoded path that contains control characters
    /// (NUL, LF, CR, TAB, etc.). The send-time
    /// `validateAttachmentPath` already screens the RAW input
    /// string, but Foundation's `URL.path` percent-decodes
    /// printable control-character escapes (`%0A`, `%0D`, `%09`)
    /// when extracting the path from a `file:` URL. (`%00` and
    /// `%2F` are NOT decoded by Foundation — those are caught by
    /// the raw screen.) So an input like
    /// `file:///tmp/x%0Ay.png` passes the raw screen (it's all
    /// printable ASCII) but classifies to a `.localPath`
    /// containing a literal LF byte. Re-screening the decoded
    /// `.localPath` closes that bypass.
    ///
    /// Throws `ValidationError` because this runs at validation
    /// time (`Send.validateAttachmentIfPresent` and the seam
    /// fixture in `Send.classifyAttachment` callers) — it's
    /// surfaced through ArgumentParser's error formatter.
    static func rejectControlCharactersInDecodedPath(_ path: String) throws {
        if path.rangeOfCharacter(from: .controlCharacters) != nil {
            throw ValidationError(
                "--attachment decoded path contains control characters "
                + "(NUL, newline, carriage return, tab, etc.). Pass "
                + "an unescaped filesystem path; control-character "
                + "filenames are not supported."
            )
        }
    }

    static func classifyAttachment(_ pathOrURL: String) -> AttachmentSource {
        let parsed = URL(string: pathOrURL)
        // POSIX-locale lowercasing because the classifier's scheme
        // comparison gates the rejected-remote branch (allow-list:
        // `attachmentRejectedRemoteSchemes` = http/https) and the
        // `.file` branch (separate path-handling rules). Under
        // `LANG=tr_TR.UTF-8`, `"FILE".lowercased()` folds to "fıle"
        // (dotless i) — which would not match the ASCII `"file"`
        // and would silently route an uppercase `FILE:///x.png`
        // into the `.otherScheme` branch (rejected outright) or
        // miss the host-stripping logic in `validateAttachmentPath`.
        // Pin to ASCII folding to defeat the locale dependency.
        let scheme = parsed?.scheme?.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let hasAuthorityMarker = pathOrURL.contains("://")

        if let scheme {
            if hasAuthorityMarker, Self.attachmentRejectedRemoteSchemes.contains(scheme) {
                return .rejectedRemoteURL(scheme: scheme)
            }
            if scheme == "file", parsed != nil {
                // Cover all three `file:` shapes:
                //   `file:///abs/path` → "/abs/path"
                //   `file:/abs/path`   → "/abs/path"
                //   `file:relative`    → "relative"
                //
                // We deliberately do NOT trust `URL.path` here:
                // Foundation's behaviour for `file:` URLs without an
                // authority diverges across SDK versions. On the
                // macOS 15.5 SDK (Xcode 16.4 CI runner)
                // `URL("file:relative/p").path == ""`; on macOS 26+
                // it returns `"relative/p"`. The classifier MUST agree
                // with `makeAttachment` on which bucket the value
                // falls into, so any SDK-dependent divergence here
                // becomes a "send-time validator passed but
                // attachment build failed with an opaque message"
                // bug.
                let decoded = Self.filePathFromRawFileURL(pathOrURL)
                if !decoded.isEmpty {
                    return .localPath(decoded)
                }
                // Fall through: `file:` with no path is meaningless;
                // hand back the raw string so the downstream error is
                // about a missing file at "file:", not a silent skip.
                return .localPath(pathOrURL)
            }
            if hasAuthorityMarker {
                return .otherScheme(scheme)
            }
            // No `://`. `URL(string:)` extracted a scheme anyway (e.g.
            // `release:v1.png` → scheme "release"), but the user
            // clearly meant a path containing a colon. Fall through.
        }

        let expanded = (pathOrURL as NSString).expandingTildeInPath
        return .localPath(expanded)
    }

    /// Extract the path component from a `file:` URL string, portable
    /// across Foundation versions that disagree on `URL.path`
    /// semantics for schemes without a `//` authority.
    ///
    /// The behaviour we match — what `URL.path` returns on macOS 26+:
    ///   * `file:///abs/path` → `/abs/path`
    ///   * `file:/abs/path`   → `/abs/path`
    ///   * `file:relative/p`  → `relative/p`
    ///   * `file:`            → `` (caller falls through to the raw
    ///     string for a clearer "no such file" error)
    ///
    /// `file://hostname/path` reaches this only as a programming
    /// error; the send-time `validateAttachmentPath` rejects host-
    /// bearing `file:` URLs before they get here.
    ///
    /// Percent-decoding mirrors `URL.path`'s contract on the modern
    /// SDK — a `file:foo%20bar` attachment should reach the kernel as
    /// `foo bar`. Decoding via `removingPercentEncoding`; on failure
    /// (malformed escape) we hand back the literal string so the
    /// downstream `lstat` produces a "no such file" diagnostic
    /// against what the user actually typed.
    ///
    /// `nonisolated static` so the classifier can call it from any
    /// context.
    static func filePathFromRawFileURL(_ raw: String) -> String {
        guard let colonIdx = raw.firstIndex(of: ":") else { return "" }
        let afterScheme = raw[raw.index(after: colonIdx)...]
        let path: Substring
        if afterScheme.hasPrefix("//") {
            // Authority form: drop the `//` and the host portion
            // (validated empty upstream), keep from the next `/`.
            let withoutAuthority = afterScheme.dropFirst(2)
            guard let pathStart = withoutAuthority.firstIndex(of: "/") else {
                // `file://` with no path component.
                return ""
            }
            path = withoutAuthority[pathStart...]
        } else {
            // Short form `file:abs/path` or `file:relative/p`.
            path = afterScheme
        }
        let str = String(path)
        return str.removingPercentEncoding ?? str
    }

    /// Build a `UNNotificationAttachment` from a local filesystem
    /// path. Remote URLs are not supported — the classifier should
    /// have routed those to `.rejectedRemoteURL` at validation time;
    /// reaching `makeAttachment` with a non-local source is a
    /// programmer error and surfaces as `AttachmentError.disallowedScheme`.
    ///
    /// - Parameters:
    ///   - pathOrURL: A filesystem path or `file://` URL.
    ///   - options: Optional `UNNotificationAttachment` options dict
    ///     (thumbnail-time, type-hint, etc.).
    /// - Returns: The built attachment. (The previous remote path
    ///   wrote a temp file the caller had to delete; the local-only
    ///   pipeline has nothing to clean up.)
    /// - Throws: `AttachmentError.unsafeLocalAttachment` on a refused
    ///   local path, `AttachmentError.disallowedScheme` if the
    ///   validator was bypassed and a remote/other-scheme URL reached
    ///   here, or any `UNNotificationAttachment.init` error.
    func makeAttachment(
        from pathOrURL: String,
        options: [String: Any]? = nil
    ) async throws -> UNNotificationAttachment {
        let resolvedURL: URL

        switch Self.classifyAttachment(pathOrURL) {
        case .localPath(let path):
            // Foundation's `URL.path` percent-decodes `%0A`/`%0D`/`%09`
            // when extracting the path component of a `file:` URL —
            // the raw-string screen in `validateAttachmentPath`
            // can't see those because they're three printable ASCII
            // bytes in the raw input. Re-screen the post-classify
            // decoded path here so a `file:///tmp/x%0Ay.png`
            // doesn't reach the filesystem with an embedded LF.
            try Self.rejectControlCharactersInDecodedPath(path)
            // Last-chance check just before handing the path to UN. The
            // send-time validator already rejects symlinks and
            // non-regular files, but a same-user attacker who can win
            // the race could swap the file between validation and use.
            // Re-checking here shrinks the window to "between this
            // `lstat` and UN's internal `open`" — still not zero, but
            // small enough that O_NOFOLLOW-style races require active
            // racing rather than passive pre-staging.
            //
            // `rejectIfUnsafeForAttachment` returns the canonical path
            // (every symlink — leaf AND intermediate — resolved by
            // `realpath(3)`) so the URL we hand to UN matches what
            // the kernel would have opened anyway. Without
            // canonicalisation, a path like `/tmp/safedir/file.png`
            // where `/tmp/safedir` is itself a symlink to a
            // privileged directory would pass the leaf-only `lstat`
            // (file.png is a regular file at the resolved target)
            // and silently attach a file from somewhere the user
            // didn't type. See doc comment on the helper for the
            // residual TOCTOU note. The error type is
            // `AttachmentError` because we're past the
            // ArgumentParser validation phase.
            let canonical = try Self.rejectIfUnsafeForAttachment(path: path)

            // Copy to a temp file before handing to UN.
            //
            // `UNNotificationAttachment.init(identifier:url:options:)`
            // on macOS *moves* the source file into the system's
            // attachment store at `add(_:)` time — different from
            // iOS, where it copies. Without this temp-copy step the
            // user's original file disappears the moment the
            // notification is posted, which is a surprising and
            // destructive behaviour the user almost never wants.
            //
            // We copy from `canonical` (the realpath-resolved, post-
            // symlink-walk path) rather than from the user's typed
            // path so the attachment content matches what the
            // security pass verified. The temp filename preserves
            // the original basename — UN uses the filename's
            // extension as a fallback for UTI inference when
            // `--attachment-type-hint` isn't set.
            //
            // Cleanup: we deliberately don't `unlink` the temp
            // file. If UN moves it (the common case), the temp is
            // gone. If UN copies it (varies by macOS version), the
            // temp lives briefly in NSTemporaryDirectory() and is
            // reaped by macOS's periodic /tmp sweep. The `roar`
            // process exits within ~100 ms of `add(_:)` anyway, so
            // long-lived temp accumulation isn't a concern.
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(
                    "io.myers.roar.attachment-\(UUID().uuidString)",
                    isDirectory: true
                )
            do {
                try FileManager.default.createDirectory(
                    at: tempDir, withIntermediateDirectories: true)
                let filename = (canonical as NSString).lastPathComponent
                let tempFile = tempDir.appendingPathComponent(filename)
                try FileManager.default.copyItem(
                    atPath: canonical, toPath: tempFile.path)
                resolvedURL = tempFile
            } catch {
                // Translate the copy failure into the same error
                // family as the other attachment-staging failures
                // so the caller's diagnostic shape stays uniform.
                throw AttachmentError.unsafeLocalAttachment(
                    path: canonical,
                    reason: .missing(errno: (error as NSError).code == NSFileWriteOutOfSpaceError
                        ? Int32(ENOSPC) : Int32((error as NSError).code))
                )
            }

        case .rejectedRemoteURL(let scheme):
            // Validation should have caught this. If it didn't, throw
            // the same user-facing error from here so the user still
            // sees the curl-first guidance rather than an opaque UN
            // failure.
            throw AttachmentError.remoteURLRejected(scheme: scheme)

        case .otherScheme(let scheme):
            throw AttachmentError.disallowedScheme(scheme)
        }

        return try UNNotificationAttachment(
            identifier: UUID().uuidString,
            url: resolvedURL,
            options: options
        )
    }

    /// Refuse a local attachment path that would unsafely escape the
    /// user's intent: a symbolic link at the leaf (the target may
    /// not be what the user typed, especially when the path lives
    /// in a shared directory like `/tmp` or under `~/Public`), a
    /// special file (FIFO, socket, block/char device), or a
    /// directory.
    ///
    /// Uses `lstat(2)` — the wrapper that does NOT follow symlinks —
    /// for the leaf-symlink rejection. This is the only way to
    /// reliably detect symlinks from Swift without dropping to
    /// `URLResourceValues` (which follows symlinks for some keys),
    /// and matches POSIX semantics users coming from `ls -l` /
    /// `find -type l` will recognise.
    ///
    /// In addition to the leaf check, `realpath(3)` is invoked to
    /// canonicalise the WHOLE path — every intermediate symlink
    /// resolved, `..`/`.` components collapsed. This closes a gap
    /// the bare leaf check missed: `/tmp/safedir/file.png` where
    /// `/tmp/safedir` is itself a symlink to a privileged directory
    /// would pass the leaf-only `lstat` (file.png is a regular file
    /// at the resolved target) and silently attach the privileged
    /// file. Returning the canonical path lets callers hand the
    /// resolved URL to UN so what they validated is what the kernel
    /// opens. A residual microsecond TOCTOU window remains between
    /// `realpath` returning and `UNNotificationAttachment.init`
    /// `open(2)`-ing the file; eliminating it would require a
    /// temp-copy intermediary (UN takes a URL, not an fd), which is
    /// not worth the disk write for this hardening tier.
    ///
    /// Note: `realpath` of a path that resolves to a different
    /// canonical form (e.g. `/tmp/foo` → `/private/tmp/foo` on
    /// macOS where `/tmp` itself is a system symlink) is NOT
    /// rejected. The security goal is "don't open a file from a
    /// location the user didn't intend," not "don't ever follow a
    /// symlink"; rejecting on path inequality would break the
    /// standard `/tmp` workflow that every macOS user relies on.
    ///
    /// Throws `AttachmentError` (rather than `ValidationError`)
    /// because callers in `makeAttachment` are past the send-time
    /// validation phase. The send-time check in
    /// `Send.validateAttachmentExistsIfLocal` translates this to
    /// `ValidationError` on the validation path.
    ///
    /// - Parameter path: A local filesystem path. `~` should already
    ///   be expanded.
    /// - Returns: The canonical path (`realpath`-resolved), suitable
    ///   for `URL(filePath:)`. Callers that don't need the canonical
    ///   form may discard the result.
    /// - Throws: `AttachmentError.unsafeLocalAttachment` if the path
    ///   is missing, is a symlink at the leaf, or is not a regular
    ///   file.
    @discardableResult
    static func rejectIfUnsafeForAttachment(path: String) throws -> String {
        var st = stat()
        // Phase 1: leaf-only `lstat` on the user-supplied path.
        // `lstat`, not `stat`: we want to inspect the link itself,
        // not its target. A symlink at the leaf — even one whose
        // target is a regular file — is still refused so the user
        // sees the diagnostic naming the link, not the silently
        // resolved target.
        guard lstat(path, &st) == 0 else {
            throw AttachmentError.unsafeLocalAttachment(
                path: path, reason: .missing(errno: errno))
        }
        let leafMode = mode_t(st.st_mode) & S_IFMT
        if leafMode == S_IFLNK {
            throw AttachmentError.unsafeLocalAttachment(
                path: path, reason: .symlink)
        }
        if leafMode != S_IFREG {
            throw AttachmentError.unsafeLocalAttachment(
                path: path, reason: .notRegularFile(mode: leafMode))
        }

        // Phase 2: walk every intermediate component, rejecting
        // any symlink whose value is NOT in the known macOS
        // system-symlink allow-list (`/tmp`, `/var`, `/etc`). This
        // closes the pre-staged-intermediate-symlink attack: an
        // attacker who creates `/tmp/safedir → /Users/victim/Library/Mail`
        // and then drops `file.png` inside would otherwise pass the
        // bare-realpath check (the canonical form is a real
        // regular file under the victim's mail directory and the
        // Phase 1 leaf `lstat` only inspects the trailing
        // component, not the directory containing it). The walk
        // makes "did this user-supplied path traverse any
        // attacker-controllable indirection" an explicit decision
        // gated on a small allow-list of OS-level system symlinks
        // that every macOS user transparently relies on.
        try walkPathRejectingNonSystemSymlinks(path)

        // Phase 3: canonicalise. `realpath` resolves every symlink
        // component (intermediate AND leaf — the system-symlink
        // allow-list above accepts e.g. `/tmp/foo` and lets
        // realpath produce `/private/tmp/foo`) and collapses
        // `..`/`.` — i.e. it returns the path the kernel would
        // actually open. Passing `nil` for the buffer makes it
        // `malloc` one we own; `free` immediately after copying.
        // On error, surface as `.missing` — a `realpath` failure
        // here means either a TOCTOU (the file vanished between
        // the walk above and now) or an unreachable component,
        // both of which the user should see as "no longer
        // accessible."
        //
        // Residual TOCTOU window: between the Phase 2 walk's last
        // `lstat` and the `realpath` syscall here, then between
        // `realpath` and `UNNotificationAttachment.init`'s
        // internal `open(2)`. Eliminating those would require an
        // fd-based UN API (which UN does not expose; it takes a
        // file URL, not a descriptor). The walk shrinks the
        // exploitable window to microseconds and requires the
        // attacker to win an active race rather than pre-staging
        // — a meaningful upgrade from "passive pre-staging
        // works."
        guard let resolved = realpath(path, nil) else {
            throw AttachmentError.unsafeLocalAttachment(
                path: path, reason: .missing(errno: errno))
        }
        defer { free(resolved) }
        let canonical = String(cString: resolved)

        // Phase 4: defence-in-depth `lstat` on the canonical path.
        // `realpath` by definition returns a path with no symlink
        // components, so this should always observe a regular file
        // if Phase 1 did — but a same-user attacker swapping the
        // file between Phases 3 and 4 would be caught here, and
        // the cost (one extra syscall) is negligible.
        guard lstat(canonical, &st) == 0 else {
            throw AttachmentError.unsafeLocalAttachment(
                path: canonical, reason: .missing(errno: errno))
        }
        let canonicalMode = mode_t(st.st_mode) & S_IFMT
        if canonicalMode == S_IFLNK {
            // Should be unreachable given `realpath`'s contract, but
            // refuse rather than trust the framework. The path used
            // in the error is the canonical one so the user can see
            // what the resolver produced.
            throw AttachmentError.unsafeLocalAttachment(
                path: canonical, reason: .symlink)
        }
        if canonicalMode != S_IFREG {
            throw AttachmentError.unsafeLocalAttachment(
                path: canonical, reason: .notRegularFile(mode: canonicalMode))
        }
        return canonical
    }

    /// Map of root-level system symlinks to their expected targets.
    /// Each entry is `(absolute symlink path, expected `readlink`
    /// value)`. macOS keeps `/tmp`, `/var`, and `/etc` as relative
    /// symlinks into `/private/...` — every macOS user (and every
    /// tool a user might `--attachment`) crosses these without
    /// noticing, so refusing them outright would break the
    /// expected `/tmp` workflow. Everything outside this small
    /// list is treated as an attacker-controllable indirection.
    ///
    /// Values are the LITERAL `readlink` output, not the resolved
    /// target. macOS's `/tmp` is `readlink`-ed as `"private/tmp"`
    /// (relative path), not `"/private/tmp"`. The walker compares
    /// against the raw `readlink` to avoid a TOCTOU on the target
    /// itself.
    ///
    /// `nonisolated static` so the walker can be unit-tested
    /// without spinning up a real filesystem layout.
    static let macOSSystemSymlinkAllowList: [String: String] = [
        "/tmp": "private/tmp",
        "/var": "private/var",
        "/etc": "private/etc",
    ]

    /// Walk `path` component by component, calling `lstat` (NOT
    /// `stat`) at each prefix. If a component IS a symlink, accept
    /// only the macOS-system-symlink shape captured in
    /// `macOSSystemSymlinkAllowList`; anything else is refused
    /// outright with `.symlink`.
    ///
    /// Leaf symlinks are NOT this function's concern — Phase 1 in
    /// `rejectIfUnsafeForAttachment` already rejected those with
    /// a leaf-focused diagnostic. The walk only inspects the
    /// intermediate components (i.e. every component except the
    /// final one) so the leaf rule's diagnostic survives.
    ///
    /// ### Trust model
    ///
    /// The walk's purpose is to defend against attacker-typed
    /// paths whose intermediate components are attacker-staged
    /// symlinks. Two distinct sources of path components flow into
    /// this function and they are NOT trusted equally:
    ///
    /// * **User-typed components** (everything in `path` when it's
    ///   absolute, or the suffix after cwd when relative) are
    ///   walked strictly — every intermediate symlink must be on
    ///   the system allow-list.
    /// * **The current working directory** is treated as a trusted
    ///   reference frame — it's the shell's choice, not user
    ///   input, and a user running `roar send --attachment foo.png`
    ///   from a cwd reachable only via a non-system symlink (e.g.
    ///   `/Users/me/dev → /Volumes/EXT/dev`) hasn't typed anything
    ///   attacker-controllable. Refusing those paths would be a
    ///   workflow break with no security upside.
    ///
    /// For relative input paths the cwd is therefore canonicalised
    /// via `realpath` (collapsing every cwd-level symlink) BEFORE
    /// being joined with the user-typed remainder. The walk then
    /// operates on `<canonical-cwd>/<user-typed-remainder>` so the
    /// strict policy only applies to the parts the user actually
    /// typed.
    ///
    /// Absolute paths are walked as-is: every component there
    /// IS user-typed.
    ///
    /// ### `..` semantics
    ///
    /// The walk does NOT pre-normalise `..` / `.` components.
    /// `lstat("/a/b/../c")` resolves the `..` lazily — if `b` is
    /// a symlink the kernel follows it before applying `..`, so
    /// the walk's per-component `lstat` catches the symlink at
    /// `/a/b`. This is deliberately the same semantics the kernel
    /// will apply at attach time, so the walk's verdict matches
    /// the eventual open.
    ///
    /// `nonisolated static` so tests can pin the policy directly.
    ///
    /// - Parameter path: The user-supplied path. May be absolute
    ///   or relative.
    /// - Throws: `AttachmentError.unsafeLocalAttachment(..., reason: .symlink)`
    ///   if any intermediate symlink is not on the allow-list;
    ///   `.missing(errno:)` if an intermediate component is
    ///   unreadable or the cwd cannot be canonicalised on the
    ///   relative-path branch; `ValidationError` if the path is
    ///   empty.
    static func walkPathRejectingNonSystemSymlinks(_ path: String) throws {
        // Empty path: there's nothing to walk and `lstat("")`
        // would surface ENOENT with a confusing diagnostic.
        // Reject up front with a clear validation error — the
        // caller's leaf `lstat` would also fail, but pinning the
        // contract here means the walk's own test surface
        // catches the empty case.
        guard !path.isEmpty else {
            throw ValidationError(
                "Attachment path cannot be empty."
            )
        }
        // Compose the absolute form to walk. For absolute paths
        // every component is user-typed and walked strictly. For
        // relative paths the cwd is canonicalised first so symlinks
        // in the shell-chosen reference frame don't false-positive;
        // see the docstring's trust-model section.
        let absolutePath: String
        if path.hasPrefix("/") {
            absolutePath = path
        } else {
            // `realpath` resolves every symlink in the cwd to
            // produce its canonical form. Passing `nil` makes
            // `realpath` `malloc` a buffer we own; `free` after
            // copying. If cwd canonicalisation fails (e.g. the
            // cwd was deleted out from under us), surface a
            // `.missing` so the diagnostic matches the rest of
            // the walk's error vocabulary.
            let cwd = FileManager.default.currentDirectoryPath
            guard let resolved = realpath(cwd, nil) else {
                throw AttachmentError.unsafeLocalAttachment(
                    path: cwd, reason: .missing(errno: errno))
            }
            let canonicalCwd = String(cString: resolved)
            free(resolved)
            absolutePath = canonicalCwd.hasSuffix("/")
                ? canonicalCwd + path
                : canonicalCwd + "/" + path
        }
        // Split into components. Use the filesystem-friendly `/`
        // separator directly: macOS paths are POSIX, and
        // `URL`-based splitting would normalise away the
        // exactness we need (leading slash, trailing slash) for
        // the allow-list check.
        let parts = absolutePath.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        // Iterate every prefix EXCEPT the full path — the leaf is
        // handled by the caller's Phase 1 check. `prefix(parts.count
        // - 1)` is the intermediate-component slice. A single
        // component (or `/`) has no intermediates to walk.
        guard parts.count > 1 else { return }
        var current = ""
        for component in parts.prefix(parts.count - 1) {
            current += "/" + component
            var st = stat()
            // `lstat`, not `stat`: we need to know if this
            // component IS a symlink. `stat` would silently follow
            // it and tell us about the target.
            if lstat(current, &st) != 0 {
                // Intermediate component missing is `.missing` —
                // matches the caller's leaf-`lstat` shape so the
                // diagnostic is consistent.
                throw AttachmentError.unsafeLocalAttachment(
                    path: current, reason: .missing(errno: errno))
            }
            let mode = mode_t(st.st_mode) & S_IFMT
            guard mode == S_IFLNK else { continue }
            // It's a symlink. Read its target and compare against
            // the allow-list. `readlink` returns the LITERAL
            // target byte string — we want to compare on the raw
            // value because resolving via `realpath` here would
            // re-introduce the very TOCTOU the walk is designed to
            // catch.
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let count = buffer.withUnsafeMutableBufferPointer { ptr in
                readlink(current, ptr.baseAddress, ptr.count - 1)
            }
            guard count > 0 else {
                // `readlink` failed (EACCES, ELOOP, EIO, …). We know
                // the component IS a symlink (Phase 1 above passed
                // `S_IFLNK`), but we couldn't read its target — so we
                // can't render the allow-list verdict. Surface as
                // `.missing` because the failure mode is "couldn't
                // inspect this component," not "the link target
                // differs from what was intended" (the `.symlink`
                // message implies we read the target and refused it,
                // which would mis-describe an EACCES).
                throw AttachmentError.unsafeLocalAttachment(
                    path: current, reason: .missing(errno: errno))
            }
            // `readlink` does NOT NUL-terminate; explicitly cap the
            // String at the byte count.
            buffer[Int(count)] = 0
            let target = String(cString: buffer)
            // POSIX-lowercase the lookup key. macOS's default
            // volume is case-insensitive, so `lstat("/TMP")` and
            // `lstat("/tmp")` resolve to the same inode — but
            // `macOSSystemSymlinkAllowList` is keyed under the
            // lowercase form, and a literal-string lookup with
            // `/TMP` would miss and (incorrectly) refuse the
            // common-case `/TMP` workflow. Using `en_US_POSIX`
            // sidesteps the Turkish-`I`-folding hazard
            // (`.lowercased()` would map `I` → `ı`, breaking the
            // ASCII match).
            let lookupKey = current.lowercased(
                with: Locale(identifier: "en_US_POSIX"))
            guard let expected = macOSSystemSymlinkAllowList[lookupKey],
                  expected == target else {
                // Not on the allow-list — refuse. The diagnostic
                // names the symlink path so the user can see where
                // the indirection lived in their input.
                throw AttachmentError.unsafeLocalAttachment(
                    path: current, reason: .symlink)
            }
        }
    }

    enum AttachmentError: LocalizedError, CustomStringConvertible {
        /// A non-`file://`, non-http(s) scheme was passed (`ftp://`,
        /// `data:`, custom handler). UN's own error would be opaque.
        case disallowedScheme(String)
        /// The user passed an `http://` or `https://` URL. Surfaced
        /// from `makeAttachment` if validation was bypassed; the
        /// validator (`validateAttachmentExistsIfLocal`) ordinarily
        /// catches this first and raises a `ValidationError` with the
        /// same guidance.
        case remoteURLRejected(scheme: String)
        case unsafeLocalAttachment(path: String, reason: UnsafeLocalReason)

        /// Why a local attachment path was refused at the last-chance
        /// check before handing the URL to `UNNotificationAttachment.init`.
        /// `missing` is included because the send-time check could have
        /// passed against a file that was then deleted before the
        /// attachment build — surfacing the specific reason is better
        /// than letting UN throw its opaque "couldn't be opened."
        enum UnsafeLocalReason: Equatable {
            /// `lstat` returned -1; the file is gone or unreachable.
            case missing(errno: Int32)
            /// Path is a symbolic link. We refuse regardless of where
            /// it points — the target may differ from what the user
            /// thinks they're attaching.
            case symlink
            /// Path exists but is not a regular file. Covers
            /// directories, FIFOs, sockets, block and char devices.
            case notRegularFile(mode: mode_t)
        }

        var description: String {
            switch self {
            case .disallowedScheme(let scheme):
                return "Attachment URL scheme '\(scheme)' is not supported. --attachment accepts local paths only; pre-download remote content with `curl -o /tmp/file URL` and pass the resulting path."
            case .remoteURLRejected(let scheme):
                return "Attachment URL scheme '\(scheme)' is not supported. --attachment accepts local paths only; pre-download with `curl -o /tmp/file URL` and pass the resulting path."
            case .unsafeLocalAttachment(let path, let reason):
                switch reason {
                case .missing(let errno):
                    return "Attachment path '\(path)' is no longer accessible (errno \(errno))."
                case .symlink:
                    return "Attachment path '\(path)' is a symbolic link. Refusing to attach because the link target may differ from what was intended; pass the real path instead."
                case .notRegularFile(let mode):
                    return "Attachment path '\(path)' is not a regular file (file type 0o\(String(mode, radix: 8))). Only plain files are supported."
                }
            }
        }

        // LocalizedError.errorDescription is what `error.localizedDescription`
        // surfaces for Swift Error types that don't bridge to NSError —
        // without this conformance the description above is hidden behind
        // a generic "error 0" message.
        var errorDescription: String? { description }
    }

    /// Surface attachment failures through ArgumentParser so they're
    /// formatted consistently with other `--option` errors and produce
    /// a non-zero exit code. Wraps the underlying error and stamps the
    /// user-supplied attachment path into the diagnostic so the user
    /// can see which `--attachment` value failed when multiple were
    /// passed.
    struct AttachmentFetchError: LocalizedError, CustomStringConvertible {
        let path: String
        let underlying: Error

        var description: String {
            "Failed to attach '\(path)': \(underlying.localizedDescription)"
        }
        var errorDescription: String? { description }
    }
}
