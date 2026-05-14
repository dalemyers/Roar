import XCTest
import ArgumentParser
@testable import roar

/// Pinned behaviour for the `--in` and `--at` parsers, plus mutual
/// exclusion. These tests do not exercise the UN trigger construction
/// itself (that's a thin wrapper around the parsed value) — only the
/// pure parsers / cross-flag rules.
final class ScheduleTriggerTests: XCTestCase {

    // MARK: - Mutual exclusion

    func testNeitherIsFine() throws {
        try Send.validateScheduleMutualExclusion(
            scheduleIn: nil, scheduleAt: nil, scheduleRepeat: nil)
    }

    func testInAloneIsFine() throws {
        try Send.validateScheduleMutualExclusion(
            scheduleIn: "5m", scheduleAt: nil, scheduleRepeat: nil)
    }

    func testAtAloneIsFine() throws {
        try Send.validateScheduleMutualExclusion(
            scheduleIn: nil, scheduleAt: "2026-12-31T00:00:00Z", scheduleRepeat: nil)
    }

    func testRepeatAloneIsFine() throws {
        try Send.validateScheduleMutualExclusion(
            scheduleIn: nil, scheduleAt: nil, scheduleRepeat: "hourly")
    }

    func testInAndAtRejected() {
        XCTAssertThrowsError(
            try Send.validateScheduleMutualExclusion(
                scheduleIn: "5m", scheduleAt: "2026-12-31T00:00:00Z",
                scheduleRepeat: nil)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    /// `--in` + `--repeat` is rejected: a one-shot delay and a
    /// recurring calendar pattern have no coherent reading.
    func testInAndRepeatRejected() {
        XCTAssertThrowsError(
            try Send.validateScheduleMutualExclusion(
                scheduleIn: "5m", scheduleAt: nil,
                scheduleRepeat: "hourly")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    /// `--at` + `--repeat` is rejected for the same reason: a single
    /// timestamp and a recurring pattern are alternative schedule
    /// shapes, not composable.
    func testAtAndRepeatRejected() {
        XCTAssertThrowsError(
            try Send.validateScheduleMutualExclusion(
                scheduleIn: nil, scheduleAt: "2026-12-31T00:00:00Z",
                scheduleRepeat: "daily:09:00")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    /// All three set — the diagnostic should still fire. The general
    /// "two or more" rule covers this, but pinning the case prevents
    /// a regression from collapsing the validator into pairwise checks.
    func testAllThreeRejected() {
        XCTAssertThrowsError(
            try Send.validateScheduleMutualExclusion(
                scheduleIn: "5m", scheduleAt: "2026-12-31T00:00:00Z",
                scheduleRepeat: "hourly")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - parseScheduleInterval

    func testParsesSeconds() throws {
        XCTAssertEqual(try Send.parseScheduleInterval("30s"), 30)
        XCTAssertEqual(try Send.parseScheduleInterval("1s"), 1)
    }

    func testParsesMinutes() throws {
        XCTAssertEqual(try Send.parseScheduleInterval("5m"), 300)
    }

    func testParsesHours() throws {
        XCTAssertEqual(try Send.parseScheduleInterval("2h"), 7200)
    }

    func testParsesDays() throws {
        XCTAssertEqual(try Send.parseScheduleInterval("1d"), 86400)
    }

    func testParsesFractionalValues() throws {
        XCTAssertEqual(try Send.parseScheduleInterval("1.5h"), 5400)
    }

    func testTrimsWhitespace() throws {
        XCTAssertEqual(try Send.parseScheduleInterval("  10m  "), 600)
    }

    func testRejectsEmpty() {
        XCTAssertThrowsError(try Send.parseScheduleInterval("")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsWhitespaceOnly() {
        XCTAssertThrowsError(try Send.parseScheduleInterval("   ")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsMissingUnit() {
        XCTAssertThrowsError(try Send.parseScheduleInterval("30")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsUnknownUnit() {
        XCTAssertThrowsError(try Send.parseScheduleInterval("5y")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsUppercaseUnit() {
        // Lowercase-only — keeps the grammar tight and lets us assume
        // `S`/`M` is a user typo rather than a different unit family.
        XCTAssertThrowsError(try Send.parseScheduleInterval("30S")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsMissingNumber() {
        XCTAssertThrowsError(try Send.parseScheduleInterval("s")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsNonNumeric() {
        XCTAssertThrowsError(try Send.parseScheduleInterval("foos")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsZero() {
        XCTAssertThrowsError(try Send.parseScheduleInterval("0s")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsNegative() {
        XCTAssertThrowsError(try Send.parseScheduleInterval("-5m")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsBelowMinimum() {
        // `minimumScheduleInterval` is 1 second; 0.5s falls below it.
        XCTAssertThrowsError(try Send.parseScheduleInterval("0.5s")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    /// Regex-pinned grammar: scientific notation must be rejected.
    /// `Double("1e10")` happily produces 10 billion, which without
    /// the regex guard would let `--in 1e10s` schedule a notification
    /// ~317 years from now.
    func testRejectsScientificNotation() {
        XCTAssertThrowsError(try Send.parseScheduleInterval("1e10s")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsHexFloat() {
        // `Double("0x1p3")` is 8.0; the regex must refuse this shape.
        XCTAssertThrowsError(try Send.parseScheduleInterval("0x1p3s")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsLeadingPlus() {
        XCTAssertThrowsError(try Send.parseScheduleInterval("+5s")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsAboveMaximum() {
        // 365 days is the cap; one more day should fail.
        XCTAssertThrowsError(try Send.parseScheduleInterval("366d")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsAbsurdValue() {
        XCTAssertThrowsError(try Send.parseScheduleInterval("999999d")) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testExactlyMaxAccepted() throws {
        // 365 days exactly should be accepted (boundary).
        XCTAssertEqual(try Send.parseScheduleInterval("365d"), 365 * 86400)
    }

    // MARK: - parseScheduleDate

    /// Reference clock used by the parser tests. Picked far enough
    /// back that 2026-12-31 is comfortably in the future regardless
    /// of when these tests run.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    // ^ 2025-06-15T22:13:20Z — gives a stable "now" anchor.

    func testParsesBasicISO8601() throws {
        let date = try Send.parseScheduleDate("2026-12-31T17:00:00Z", now: now)
        let comps = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 12)
        XCTAssertEqual(comps.day, 31)
        XCTAssertEqual(comps.hour, 17)
    }

    func testParsesOffsetForm() throws {
        let date = try Send.parseScheduleDate(
            "2026-12-31T17:00:00+01:00", now: now)
        let comps = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.hour, 16) // +01:00 → 16:00Z
    }

    func testParsesFractionalSeconds() throws {
        // `.withFractionalSeconds` is the second-chance branch in the
        // parser; make sure it actually catches this form AND that
        // the fractional component is preserved, not truncated. A
        // bare `XCTAssertGreaterThan(date, now)` would pass even if
        // the parser silently dropped `.123` — the test was the
        // shape of "did it return *something* in the future," not
        // "did it parse the fractional value." Pin the actual
        // fractional remainder so a regression that drops fractional
        // seconds is visible.
        let date = try Send.parseScheduleDate(
            "2026-12-31T17:00:00.123Z", now: now)
        XCTAssertGreaterThan(date, now)
        let fractional = date.timeIntervalSince1970.truncatingRemainder(
            dividingBy: 1)
        // `accuracy: 0.001` so a future implementation that stores
        // milliseconds (the maximum useful fraction for ISO 8601
        // .withFractionalSeconds) doesn't fail on sub-ms rounding.
        XCTAssertEqual(fractional, 0.123, accuracy: 0.001)
    }

    func testTrimsWhitespaceInDate() throws {
        // Pin equality against the un-padded form. The previous
        // `XCTAssertNoThrow` shape would pass even if the trim silently
        // produced a wrong-but-non-throwing Date (e.g. parser falling
        // through to a different format that happened to accept the
        // padded string and returned a stale-but-future date). Asserting
        // round-trip equality with the canonical form forces the
        // whitespace-stripping branch to actually run.
        let padded = try Send.parseScheduleDate(
            "  2026-12-31T17:00:00Z  ", now: now)
        let canonical = try Send.parseScheduleDate(
            "2026-12-31T17:00:00Z", now: now)
        XCTAssertEqual(padded, canonical)
    }

    func testRejectsEmptyDate() {
        XCTAssertThrowsError(try Send.parseScheduleDate("", now: now)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsMalformedDate() {
        XCTAssertThrowsError(
            try Send.parseScheduleDate("tomorrow at 5pm", now: now)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testRejectsPastDate() {
        XCTAssertThrowsError(
            try Send.parseScheduleDate("2020-01-01T00:00:00Z", now: now)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testRejectsDateEqualToNow() {
        // `parseScheduleDate` now enforces the
        // `minimumScheduleInterval` floor up-front instead of letting
        // the resolver silently clamp sub-floor values to "1 second
        // from now." A timestamp equal to `now` resolves to a 0-second
        // delta, which falls below the floor and is rejected with the
        // distinct "too close to now" diagnostic (not the strict-past
        // message).
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let iso8601Now = iso.string(from: now)
        XCTAssertThrowsError(try Send.parseScheduleDate(iso8601Now, now: now)) {
            XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))")
        }
    }

    func testRejectsNearFutureBelowFloor() {
        // A timestamp 0.5s in the future is past the strict-past
        // check (`date >= now`) but inside the
        // `minimumScheduleInterval` window. Pre-fix this got silently
        // rewritten to "1 second from now"; the contract is now that
        // it's rejected with a "too close to now" diagnostic.
        let target = now.addingTimeInterval(0.5)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds]
        let raw = iso.string(from: target)
        XCTAssertThrowsError(try Send.parseScheduleDate(raw, now: now)) {
            guard let validation = $0 as? ValidationError else {
                XCTFail("got \(type(of: $0))")
                return
            }
            // Distinct from the strict-past message: it must mention
            // the floor and the "too close to now" framing rather
            // than the "in the past" framing. Pin this loosely (no
            // exact-string match) so future copy edits don't trip
            // the test.
            let text = "\(validation)"
            XCTAssertTrue(
                text.contains("too close to now"),
                "expected near-future diagnostic, got: \(text)"
            )
        }
    }

    func testAcceptsAtMinimumFloorFuture() throws {
        // Boundary: a timestamp exactly `minimumScheduleInterval`
        // seconds in the future should pass. Tests use `>=` not `>`
        // on the floor.
        //
        // Pin equality against the input target instead of bare
        // no-throw: a regression that parsed to the wrong-but-still-
        // future Date (e.g. dropped to whole-second precision and
        // happened to land on the right side of the floor) would not
        // have tripped `XCTAssertNoThrow`. ISO 8601 without
        // fractional seconds is whole-second precision, so an exact
        // equality check is well-defined here.
        let target = now.addingTimeInterval(Send.minimumScheduleInterval)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let raw = iso.string(from: target)
        let parsed = try Send.parseScheduleDate(raw, now: now)
        // Whole-second precision: assert near-equality so a sub-ms
        // round-trip wobble can't trip a future implementation change.
        XCTAssertEqual(parsed.timeIntervalSince1970,
                       target.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testAcceptsFutureBeyondFloor() throws {
        // 2 seconds in the future is comfortably past the floor.
        //
        // Same rationale as `testAcceptsAtMinimumFloorFuture`: pin
        // equality so a regression that silently mis-parsed the
        // timestamp would surface.
        let target = now.addingTimeInterval(2.0)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let raw = iso.string(from: target)
        let parsed = try Send.parseScheduleDate(raw, now: now)
        XCTAssertEqual(parsed.timeIntervalSince1970,
                       target.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    // MARK: - Relaxed --at formats

    /// Local-time T-separator without a zone — interpreted in the
    /// current system timezone. The expected wall-clock components
    /// in the local zone must match exactly; the absolute Date
    /// shifts with the system offset, so the comparison goes
    /// through `Calendar.current` rather than against a fixed UTC
    /// epoch second.
    func testParsesLocalTimeISOFormatWithoutZone() throws {
        // Use a far-future target so the floor check doesn't reject.
        // `2099-06-15 14:30:00` is unambiguously in the future.
        let raw = "2099-06-15T14:30:00"
        let parsed = try Send.parseScheduleDate(raw, now: now)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone.current
        let comps = local.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: parsed)
        XCTAssertEqual(comps.year, 2099)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 14)
        XCTAssertEqual(comps.minute, 30)
        XCTAssertEqual(comps.second, 0)
    }

    /// Local-time space-separator without a zone — the "human-typed"
    /// shape (`date '+%F %T'` output, shell hand-typed schedules).
    func testParsesLocalTimeSpaceSeparator() throws {
        let raw = "2099-06-15 14:30:00"
        let parsed = try Send.parseScheduleDate(raw, now: now)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone.current
        let comps = local.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: parsed)
        XCTAssertEqual(comps.year, 2099)
        XCTAssertEqual(comps.hour, 14)
        XCTAssertEqual(comps.minute, 30)
        XCTAssertEqual(comps.second, 0)
    }

    /// Local-time without seconds — convenience for "8pm tomorrow"
    /// style schedules.
    func testParsesLocalTimeNoSeconds() throws {
        let raw = "2099-06-15 20:00"
        let parsed = try Send.parseScheduleDate(raw, now: now)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone.current
        let comps = local.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: parsed)
        XCTAssertEqual(comps.year, 2099)
        XCTAssertEqual(comps.hour, 20)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.second, 0)
    }

    /// Date-only — midnight local on that day. The pin verifies the
    /// hour/minute/second are all zero in local time, so a regression
    /// that smuggled a UTC midnight (and therefore a non-zero local
    /// hour east of UTC) is visible.
    func testParsesDateOnlyAsLocalMidnight() throws {
        let raw = "2099-06-15"
        let parsed = try Send.parseScheduleDate(raw, now: now)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone.current
        let comps = local.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: parsed)
        XCTAssertEqual(comps.year, 2099)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.second, 0)
    }

    /// Strict parsing: a wall-clock value the user obviously typed
    /// wrong (`25:00`) must NOT roll over to "next day 1am" via the
    /// formatter's lenient mode. Surface the typo instead.
    func testRejectsOutOfRangeLocalTime() {
        XCTAssertThrowsError(
            try Send.parseScheduleDate("2099-06-15 25:00:00", now: now)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    /// Garbage that looks date-like but isn't valid in any accepted
    /// shape still rejects.
    func testStillRejectsHumanLanguage() {
        XCTAssertThrowsError(
            try Send.parseScheduleDate("next Tuesday at 5pm", now: now)
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }
}
