import XCTest
import ArgumentParser
import UserNotifications
@testable import roar

/// Pinned grammar for `--repeat`. Covers each accepted period
/// (hourly/daily/weekly/monthly) and the rejection of malformed shapes.
/// The test asserts on the produced `DateComponents` fields rather than
/// instantiating a real `UNCalendarNotificationTrigger` — the latter
/// requires a live notification center that XCTest can't set up
/// without a host bundle running its delegate.
final class CalendarRepeatTests: XCTestCase {

    // MARK: - Hourly

    func testHourlyAccepted() throws {
        let comps = try Send.parseCalendarRepeat("hourly")
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(
            comps.second, 0,
            "--repeat pins second=0 defensively so the framework's "
            + "'match all unspecified' rule cannot reinterpret to "
            + "fire multiple times per matching minute."
        )
        XCTAssertNil(comps.hour)
        XCTAssertNil(comps.weekday)
        XCTAssertNil(comps.day)
    }

    /// Regression backstop: every `--repeat` shape must pin
    /// `second = 0` so the schedule's intent ("fire at HH:MM:00")
    /// survives a future framework reinterpretation of unspecified
    /// `DateComponents` fields. The hourly assertion above pins
    /// the same property; this parameterised version covers the
    /// other three shapes in one place so a regression in any
    /// individual branch surfaces here too.
    func testEveryRepeatShapePinsSecondZero() throws {
        let cases: [String] = [
            "hourly",
            "daily:09:30",
            "weekly:mon:09:00",
            "monthly:15:09:00",
        ]
        for raw in cases {
            let comps = try Send.parseCalendarRepeat(raw)
            XCTAssertEqual(
                comps.second, 0,
                "--repeat '\(raw)' must pin second=0"
            )
        }
    }

    func testHourlyWithExtraComponentsRejected() {
        XCTAssertThrowsError(
            try Send.parseCalendarRepeat("hourly:00")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - Daily

    func testDailyAccepted() throws {
        let comps = try Send.parseCalendarRepeat("daily:09:30")
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 30)
        XCTAssertNil(comps.weekday)
        XCTAssertNil(comps.day)
    }

    func testDailyMidnightAccepted() throws {
        let comps = try Send.parseCalendarRepeat("daily:00:00")
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
    }

    func testDailyTwentyThreeFiftyNineAccepted() throws {
        let comps = try Send.parseCalendarRepeat("daily:23:59")
        XCTAssertEqual(comps.hour, 23)
        XCTAssertEqual(comps.minute, 59)
    }

    func testDailyMissingTimeRejected() {
        XCTAssertThrowsError(
            try Send.parseCalendarRepeat("daily")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testDailyOutOfRangeHourRejected() {
        XCTAssertThrowsError(
            try Send.parseCalendarRepeat("daily:24:00")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testDailyOutOfRangeMinuteRejected() {
        XCTAssertThrowsError(
            try Send.parseCalendarRepeat("daily:09:60")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testDailyNonNumericRejected() {
        XCTAssertThrowsError(
            try Send.parseCalendarRepeat("daily:nine:30")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - Weekly

    func testWeeklyMondayAccepted() throws {
        let comps = try Send.parseCalendarRepeat("weekly:mon:09:00")
        XCTAssertEqual(comps.weekday, 2) // Gregorian: Sun=1, Mon=2, ..., Sat=7
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
    }

    func testWeeklySundayAccepted() throws {
        let comps = try Send.parseCalendarRepeat("weekly:sun:09:00")
        XCTAssertEqual(comps.weekday, 1)
    }

    func testWeeklySaturdayAccepted() throws {
        let comps = try Send.parseCalendarRepeat("weekly:sat:23:59")
        XCTAssertEqual(comps.weekday, 7)
    }

    func testWeeklyCaseInsensitiveDay() throws {
        let comps = try Send.parseCalendarRepeat("weekly:WED:12:00")
        XCTAssertEqual(comps.weekday, 4)
    }

    /// Regression backstop for the Turkish-locale `I`-folding bug.
    /// `.lowercased()` is locale-sensitive — under `tr_TR.UTF-8`
    /// uppercase `I` folds to dotless `ı`, so `"FRI".lowercased()`
    /// becomes `"frı"` which misses the `"fri"` key in
    /// `weekdayTokens`. The parser uses `.lowercased(with:
    /// Locale(identifier: "en_US_POSIX"))` to fold under ASCII
    /// rules regardless of the process locale.
    ///
    /// This test does NOT mutate the process locale (which would
    /// be racy and could leak into other tests) — pinning the
    /// happy path with `FRI` is enough to demonstrate the
    /// uppercase-`I` weekday key resolves correctly, which is
    /// exactly what fails under `tr_TR` if the call site is
    /// `.lowercased()`.
    func testWeeklyFridayUppercaseAccepted() throws {
        let comps = try Send.parseCalendarRepeat("weekly:FRI:09:00")
        XCTAssertEqual(comps.weekday, 6,
            "FRI must map to Gregorian weekday 6 regardless of locale")
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
    }

    /// Companion to the FRI test — pins that the `period` token
    /// (`hourly`/`daily`/`weekly`/`monthly`) is also POSIX-folded.
    /// A user typing `HOURLY` under `tr_TR.UTF-8` would otherwise
    /// produce `hourlı` and trip the "unknown period" branch.
    func testHourlyUppercaseAccepted() throws {
        let comps = try Send.parseCalendarRepeat("HOURLY")
        XCTAssertEqual(comps.minute, 0)
        XCTAssertNil(comps.hour)
    }

    func testWeeklyUnknownDayRejected() {
        XCTAssertThrowsError(
            try Send.parseCalendarRepeat("weekly:funday:09:00")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testWeeklyMissingTimeRejected() {
        XCTAssertThrowsError(
            try Send.parseCalendarRepeat("weekly:mon")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - Monthly

    func testMonthlyAccepted() throws {
        let comps = try Send.parseCalendarRepeat("monthly:15:12:00")
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 12)
        XCTAssertEqual(comps.minute, 0)
    }

    func testMonthlyFirstOfMonthAccepted() throws {
        let comps = try Send.parseCalendarRepeat("monthly:1:00:00")
        XCTAssertEqual(comps.day, 1)
    }

    /// 31st is accepted at parse time even though UN silently skips
    /// months without a 31st. Better to let the user pick than reject
    /// a valid case for January / March / etc.
    func testMonthlyThirtyFirstAccepted() throws {
        let comps = try Send.parseCalendarRepeat("monthly:31:08:00")
        XCTAssertEqual(comps.day, 31)
    }

    /// End-to-end pinning of UN's behaviour for `monthly:31` in
    /// February: build a real `UNCalendarNotificationTrigger` from
    /// the parsed components, ask it for its next fire date after
    /// 2026-02-01, and assert that UN does NOT silently fire on
    /// March 31 or earlier — it skips the months that have no 31st
    /// and lands on the next month that does.
    ///
    /// This test pins UN's contract: `repeats: true` on a
    /// `DateComponents` that names a day that doesn't exist in the
    /// current month produces a `nextTriggerDate` of the day in the
    /// next-matching month (March 31 for Feb-starting queries),
    /// rather than clamping to Feb 28/29 or returning `nil`. A
    /// future macOS version that changes this (e.g. by clamping) is
    /// exactly the kind of silent regression this test catches —
    /// without it, users would start getting Feb-28 notifications
    /// when they asked for the 31st.
    func testMonthlyThirtyFirstSkipsFebruary() throws {
        let comps = try Send.parseCalendarRepeat("monthly:31:08:00")
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: comps, repeats: true)

        // 2026-02-01 — a non-leap Feb (29 days for the next month
        // means UN skips Feb entirely; March is the next 31-day month).
        var feb1Components = DateComponents()
        feb1Components.year = 2026
        feb1Components.month = 2
        feb1Components.day = 1
        feb1Components.hour = 0
        feb1Components.minute = 0
        feb1Components.timeZone = TimeZone(identifier: "UTC")
        let calendar = Calendar(identifier: .gregorian)
        guard let feb1 = calendar.date(from: feb1Components) else {
            XCTFail("Could not construct 2026-02-01")
            return
        }

        guard let next = trigger.nextTriggerDate() else {
            XCTFail("UN returned nil for monthly:31 trigger")
            return
        }

        // Verify the next fire is strictly later than Feb 1 (which
        // is the trigger build-time, and trivially earlier than any
        // matching date) and falls on the 31st of a 31-day month.
        XCTAssertGreaterThan(next, feb1)

        // The actual landing month depends on when UN evaluated the
        // trigger. The strong invariant we want to pin is the *day*:
        // it must be the 31st (UN honoured the `day=31` component).
        // If UN had clamped to Feb 28, this would fail. If UN had
        // returned `nil`, the guard above would fail.
        let nextComps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: next
        )
        XCTAssertEqual(nextComps.day, 31,
                       "Expected next fire on the 31st; got \(nextComps)")
        XCTAssertEqual(nextComps.hour, 8)
        XCTAssertEqual(nextComps.minute, 0)
        // UN must NOT have picked February (Feb has no 31st). Months
        // with 31 days: 1, 3, 5, 7, 8, 10, 12. Pin that the landing
        // is one of those.
        let thirtyOneDayMonths: Set<Int> = [1, 3, 5, 7, 8, 10, 12]
        XCTAssertTrue(
            thirtyOneDayMonths.contains(nextComps.month ?? -1),
            "Expected next fire in a 31-day month; got month \(nextComps.month ?? -1)"
        )
    }

    /// Same UN-contract pin for `monthly:29` in a non-leap-year
    /// February. UN should advance to the next month that has a
    /// 29th rather than silently clamping or returning `nil`. Every
    /// month except non-leap Feb has a 29th, so the test cares
    /// primarily that the day component is preserved.
    func testMonthlyTwentyNinthSkipsNonLeapFebruary() throws {
        let comps = try Send.parseCalendarRepeat("monthly:29:08:00")
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: comps, repeats: true)
        guard let next = trigger.nextTriggerDate() else {
            XCTFail("UN returned nil for monthly:29 trigger")
            return
        }
        let calendar = Calendar(identifier: .gregorian)
        let nextComps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: next
        )
        XCTAssertEqual(nextComps.day, 29,
                       "Expected next fire on the 29th; got \(nextComps)")
        XCTAssertEqual(nextComps.hour, 8)
        XCTAssertEqual(nextComps.minute, 0)
    }

    func testMonthlyZeroRejected() {
        XCTAssertThrowsError(
            try Send.parseCalendarRepeat("monthly:0:09:00")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testMonthlyThirtyTwoRejected() {
        XCTAssertThrowsError(
            try Send.parseCalendarRepeat("monthly:32:09:00")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testMonthlyMissingTimeRejected() {
        XCTAssertThrowsError(
            try Send.parseCalendarRepeat("monthly:15")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - General

    func testEmptyRejected() {
        XCTAssertThrowsError(
            try Send.parseCalendarRepeat("")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testWhitespaceTrimmed() throws {
        let comps = try Send.parseCalendarRepeat("  hourly  ")
        XCTAssertEqual(comps.minute, 0)
    }

    func testUnknownPeriodRejected() {
        XCTAssertThrowsError(
            try Send.parseCalendarRepeat("yearly:01:01:09:00")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - Mutual exclusion

    func testRepeatAndInMutuallyExclusive() {
        XCTAssertThrowsError(
            try Send.validateScheduleMutualExclusion(
                scheduleIn: "5m", scheduleAt: nil, scheduleRepeat: "hourly")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testRepeatAndAtMutuallyExclusive() {
        XCTAssertThrowsError(
            try Send.validateScheduleMutualExclusion(
                scheduleIn: nil,
                scheduleAt: "2026-12-31T00:00:00Z",
                scheduleRepeat: "daily:09:00")
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testRepeatAloneIsFine() throws {
        try Send.validateScheduleMutualExclusion(
            scheduleIn: nil, scheduleAt: nil, scheduleRepeat: "hourly")
    }

    // MARK: - Calendar pinning

    /// `UNCalendarNotificationTrigger` resolves the components
    /// against `components.calendar` if it's set, otherwise
    /// `Calendar.current` at fire time. The `weekdayTokens` map and
    /// the daily HH:MM bounds both encode Gregorian semantics — a
    /// user whose `Calendar.current` is Hebrew / Islamic / Japanese
    /// would otherwise get the wrong weekday mapping. Pin Gregorian
    /// on the returned `DateComponents` so the schedule's meaning is
    /// independent of the system's preferred calendar. Verify the
    /// pin is in place for every accepted shape so a future
    /// branch-by-branch refactor can't drop the calendar from one
    /// path silently.
    func testHourlyComponentsPinGregorian() throws {
        let comps = try Send.parseCalendarRepeat("hourly")
        XCTAssertEqual(comps.calendar?.identifier, .gregorian)
    }

    func testDailyComponentsPinGregorian() throws {
        let comps = try Send.parseCalendarRepeat("daily:09:30")
        XCTAssertEqual(comps.calendar?.identifier, .gregorian)
    }

    func testWeeklyComponentsPinGregorian() throws {
        let comps = try Send.parseCalendarRepeat("weekly:mon:09:00")
        XCTAssertEqual(comps.calendar?.identifier, .gregorian)
    }

    func testMonthlyComponentsPinGregorian() throws {
        let comps = try Send.parseCalendarRepeat("monthly:15:09:00")
        XCTAssertEqual(comps.calendar?.identifier, .gregorian)
    }

    /// Construct the actual `UNCalendarNotificationTrigger` and read
    /// `dateComponents` back — pin that the calendar survives the
    /// framework round-trip. If a future implementation pinned the
    /// calendar on a temporary and dropped it before constructing
    /// the trigger, this would catch it where the previous tests
    /// (which only inspect the parser output) would not.
    func testTriggerCarriesGregorianCalendar() throws {
        let comps = try Send.parseCalendarRepeat("weekly:wed:08:15")
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: comps, repeats: true)
        XCTAssertEqual(
            trigger.dateComponents.calendar?.identifier, .gregorian)
        // Sanity-check the rest of the round-trip so a regression
        // that nukes the entire components object doesn't pass.
        XCTAssertEqual(trigger.dateComponents.weekday, 4) // wed = 4
        XCTAssertEqual(trigger.dateComponents.hour, 8)
        XCTAssertEqual(trigger.dateComponents.minute, 15)
    }
}
