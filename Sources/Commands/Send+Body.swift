import ArgumentParser
import Darwin
import Foundation

extension Send {
    /// Maximum bytes of piped stdin to read when `--body` is omitted.
    /// Prevents a runaway pipe from blowing up memory.
    static let stdinMaxBytes = 1 * 1024 * 1024 // 1 MB

    /// Resolve the notification body from `--body` or piped stdin.
    /// Trims surrounding whitespace and trailing newlines so piped
    /// commands like `echo foo | roar` produce a clean
    /// single-line body.
    ///
    /// - Returns: The resolved, trimmed, non-empty body string.
    /// - Throws: `ValidationError` if no body was supplied.
    func resolveBody() throws -> String {
        var resolved = body
        var source = "--body"
        if resolved == nil, isatty(fileno(stdin)) == 0 {
            source = "Piped input"
            let result = try Self.readCapped(
                from: FileHandle.standardInput,
                maxBytes: Self.stdinMaxBytes,
                overflowProbeTimeoutMs: Self.stdinOverflowProbeTimeoutMs
            )
            if case .possiblyTruncated = result {
                // The cap was filled but the writer never signalled EOF
                // within the probe window. We've decided not to block
                // the CLI on a paused writer, so emit a warning instead
                // — the user can grow the body or fix the writer if
                // truncation matters to them. Silent truncation, the
                // previous behaviour, made this case undebuggable.
                let msg = "warning: piped input filled the "
                    + "\(Self.stdinMaxBytes)-byte cap and the writer did "
                    + "not close within "
                    + "\(Self.stdinOverflowProbeTimeoutMs)ms; the body "
                    + "may be truncated.\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
            // Distinguish "writer sent invalid UTF-8" from "writer sent
            // nothing." The decode helper throws on invalid sequences
            // rather than collapsing to nil-then-empty-string, which
            // would otherwise produce the misleading "Provide --body"
            // error below when the actual problem is encoding.
            resolved = try Self.decodePipedBodyUTF8(result.data)
        }
        try Self.rejectNULInBody(resolved, source: source)
        let trimmed = resolved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw ValidationError("Provide --body, or pipe a body via stdin.")
        }
        return trimmed
    }

    /// Decode the raw bytes drained from stdin as UTF-8, rejecting
    /// invalid sequences with a specific diagnostic. Split out from
    /// `resolveBody` so tests can drive the decode path without
    /// constructing a real `Send` invocation and without redirecting
    /// the process stdin.
    ///
    /// `String(data:encoding:.utf8)` returns nil on invalid sequences
    /// (e.g. a raw `\xff\xfe` BOM-without-text, a partial multi-byte
    /// char at EOF). Without this distinct error the caller's
    /// `?? ""` fallback would surface the misleading "Provide --body"
    /// message when the actual problem is encoding, not absence.
    ///
    /// `nonisolated static` so tests can call it directly.
    ///
    /// - Parameter data: The raw bytes drained from stdin.
    /// - Returns: The decoded UTF-8 string.
    /// - Throws: `ValidationError` if `data` is not valid UTF-8. The
    ///   error message mentions "UTF-8" so consumers know the bytes
    ///   reached the process but were unparseable, vs. an empty pipe.
    static func decodePipedBodyUTF8(_ data: Data) throws -> String {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw ValidationError(
                "Piped input is not valid UTF-8. Re-encode the body "
                + "before piping it in, or pass --body directly."
            )
        }
        return decoded
    }

    /// Reject a notification body whose UTF-8 contains an embedded NUL
    /// byte. Applied to both `--body` and stdin-piped input.
    ///
    /// NUL truncates at every C-string bridge downstream consumers
    /// might cross: syslog / `os_log`, JSON loggers that drop to libc
    /// for string formatting, and the XPC string field UN serialises
    /// `UNMutableNotificationContent.body` into. A NUL-bearing body
    /// would silently appear truncated in some surfaces (the unified
    /// log) but intact in others (the visible notification banner),
    /// which is the worst kind of bug to debug. Apply the same
    /// discipline as `--identifier`.
    ///
    /// `nonisolated static` so tests can drive it without standing up
    /// a full `Send` invocation.
    ///
    /// - Parameters:
    ///   - body: The resolved body. `nil` and NUL-free values pass.
    ///   - source: Human-readable name of where the body came from
    ///     (`"--body"` or `"Piped input"`). Used to personalise the
    ///     error message.
    /// - Throws: `ValidationError` if `body` is non-nil and contains
    ///   a NUL.
    static func rejectNULInBody(_ body: String?, source: String) throws {
        guard let body, body.contains("\0") else { return }
        throw ValidationError(
            "\(source) contains a NUL byte. NUL truncates downstream "
            + "string consumers (syslog, JSON loggers, XPC bridges); "
            + "strip it before sending."
        )
    }

    /// Grace window for the post-cap overflow probe. Long enough that a
    /// shell pipeline that closes promptly will signal EOF; short enough
    /// that a pathologically paused writer doesn't hang the process.
    static let stdinOverflowProbeTimeoutMs: Int32 = 500

    /// Outcome of `readCapped`. The caller wants to distinguish a clean
    /// drain (writer closed before or at the cap) from a pathological
    /// "we filled the cap but the writer is still alive" so it can warn
    /// about possible truncation.
    enum CappedReadResult: Equatable {
        /// Writer closed its end of the pipe before or at the cap.
        case complete(Data)
        /// Cap was reached and the overflow-probe `poll` returned no
        /// activity within the timeout. The bytes are valid but the
        /// writer may have had more to send.
        case possiblyTruncated(Data)

        /// The collected bytes regardless of outcome.
        var data: Data {
            switch self {
            case .complete(let data), .possiblyTruncated(let data): return data
            }
        }
    }

    /// Read up to `maxBytes` from `handle`. Prevents an unbounded pipe
    /// from exhausting memory.
    ///
    /// Uses `read(upToCount:)` rather than `availableData`: the former
    /// blocks until either bytes arrive or the writer closes its end,
    /// which is the contract we want for "drain the pipe." `availableData`
    /// can spuriously return empty for a momentary buffer underrun on a
    /// slow writer, truncating the body.
    ///
    /// When the cap is hit, uses `poll(2)` to check whether more bytes
    /// are available before reading them. `poll` returns immediately on
    /// EOF (writer closed), so a writer that sent exactly `maxBytes`
    /// then closed doesn't incur the timeout. A non-closing writer that
    /// paused at exactly the cap times out after
    /// `overflowProbeTimeoutMs` and the function returns
    /// `.possiblyTruncated` rather than hanging.
    ///
    /// Internal `static` so tests can drive it with a `Pipe`-backed
    /// `FileHandle` instead of process stdin.
    ///
    /// - Parameters:
    ///   - handle: Source of bytes. The function reads via blocking
    ///     `read(upToCount:)` and probes via `poll` on
    ///     `handle.fileDescriptor`.
    ///   - maxBytes: Cap on bytes the caller is willing to buffer.
    ///   - overflowProbeTimeoutMs: How long the poll waits at the cap
    ///     before giving up and returning `.possiblyTruncated`.
    /// - Returns: `.complete(data)` if the writer closed before or at
    ///   the cap; `.possiblyTruncated(data)` if the cap was filled and
    ///   the writer was still alive when the probe timed out.
    /// - Throws: `ValidationError` if more than `maxBytes` was
    ///   available on the pipe, or on I/O failure.
    static func readCapped(
        from handle: FileHandle,
        maxBytes: Int,
        overflowProbeTimeoutMs: Int32
    ) throws -> CappedReadResult {
        var collected = Data()
        while collected.count < maxBytes {
            let remaining = maxBytes - collected.count
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: remaining)
            } catch {
                // Surface real I/O errors instead of silently treating
                // them as EOF and truncating the body. The previous
                // `try?` here masked, e.g., a closed-while-reading pipe
                // as a clean end-of-stream.
                throw ValidationError(
                    "Failed to read piped input: \(error.localizedDescription)"
                )
            }
            guard let chunk, !chunk.isEmpty else {
                return .complete(collected)
            }
            collected.append(chunk)
        }
        // Cap hit. Poll for readiness before reading: poll returns >0
        // when either data is buffered OR the writer closed (POLLHUP),
        // and 0 on timeout. Without this guard a writer that sends
        // exactly the cap and then sleeps (without closing) would block
        // the probe `read` indefinitely.
        var pfd = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let pollResult = withUnsafeMutablePointer(to: &pfd) {
            poll($0, 1, overflowProbeTimeoutMs)
        }
        guard pollResult > 0 else {
            // Timeout (writer paused) or poll error. Signal possible
            // truncation up to the caller — pathological writer
            // behaviour is not worth blocking the CLI on, but a silent
            // truncation is worth flagging.
            return .possiblyTruncated(collected)
        }
        // Pipe is readable; read 1 byte. Empty = clean EOF (writer
        // closed at exactly the cap), non-empty = overflow.
        let overflow: Data?
        do {
            overflow = try handle.read(upToCount: 1)
        } catch {
            throw ValidationError(
                "Failed to read piped input: \(error.localizedDescription)"
            )
        }
        if let overflow, !overflow.isEmpty {
            throw ValidationError(
                "Piped input exceeds the \(maxBytes)-byte limit. "
                + "Shorten the body before piping it in."
            )
        }
        return .complete(collected)
    }
}
