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

    /// Pins UN's *actual* contract for `monthly:31` when the relevant
    /// month has no 31st. Contrary to a natural expectation, UN does
    /// NOT skip to the next 31-day month — verified on macOS 26.5, it
    /// resolves the non-existent date using the
    /// `.nextTimePreservingSmallerComponents` matching policy, which
    /// rolls the fire FORWARD to the 1st of the following month. So
    /// `monthly:31` evaluated during a 30-day month fires on the 1st,
    /// not the 31st.
    ///
    /// The earlier version of this test asserted the day was always 31
    /// and was silently date-dependent: it read the real wall clock via
    /// `nextTriggerDate()`, so it passed when run during a 31-day month
    /// and failed during a 30-day month (e.g. June). Both assertions
    /// below are independent of the run date.
    ///
    /// 1. A pinned-reference `Calendar` check documents the exact
    ///    rollover (June → July 1) with no dependency on `Date()`.
    /// 2. A live check pins that UN itself still uses this policy, so a
    ///    future macOS that switches the trigger to `.strict` (which
    ///    *would* skip to the next 31-day month) is caught.
    func testMonthlyThirtyFirstRollsToFirstOfNextMonth() throws {
        let comps = try Send.parseCalendarRepeat("monthly:31:08:00")
        let calendar = Calendar(identifier: .gregorian)

        // (1) Deterministic: from mid-June 2026 (a 30-day month), the
        // preserving-smaller-components policy rolls "June 31 08:00"
        // forward to July 1 08:00. `.strict` would instead skip to
        // July 31 — asserting day == 1 pins that UN is NOT using strict.
        var refComps = DateComponents()
        refComps.year = 2026
        refComps.month = 6
        refComps.day = 15
        refComps.hour = 12
        refComps.minute = 0
        refComps.timeZone = TimeZone.current
        let ref = try XCTUnwrap(
            calendar.date(from: refComps), "Could not construct 2026-06-15")
        let rolled = try XCTUnwrap(
            calendar.nextDate(
                after: ref, matching: comps,
                matchingPolicy: .nextTimePreservingSmallerComponents),
            "Calendar returned nil for monthly:31 from June 15")
        let rolledComps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: rolled)
        XCTAssertEqual(rolledComps.month, 7,
                       "Expected rollover into July; got \(rolledComps)")
        XCTAssertEqual(rolledComps.day, 1,
                       "Expected rollover to the 1st (not a skip to the 31st); got \(rolledComps)")
        XCTAssertEqual(rolledComps.hour, 8)
        XCTAssertEqual(rolledComps.minute, 0)

        // (2) Live: the real trigger's next fire agrees with the
        // preserving-smaller-components policy evaluated at the same
        // instant. The two calls sample `now` microseconds apart and
        // the policy preserves sub-minute components, so exact equality
        // would be brittle — a tolerance absorbs the inter-call delta.
        // A *policy change* (e.g. to `.strict`) moves the fire by days,
        // far outside this window, so the regression is still caught.
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: comps, repeats: true)
        let unNext = try XCTUnwrap(
            trigger.nextTriggerDate(), "UN returned nil for monthly:31 trigger")
        let policyNext = try XCTUnwrap(
            Calendar.current.nextDate(
                after: Date(), matching: comps,
                matchingPolicy: .nextTimePreservingSmallerComponents),
            "Calendar returned nil for live monthly:31")
        XCTAssertEqual(
            unNext.timeIntervalSince(policyNext), 0, accuracy: 90,
            "UN's matching policy diverged from .nextTimePreservingSmallerComponents")
    }

    /// Same rollover-contract pin for `monthly:29` in a non-leap-year
    /// February. Like `monthly:31`, UN does NOT skip to the next month
    /// that has a 29th — verified on macOS 26.5, the
    /// `.nextTimePreservingSmallerComponents` policy rolls a non-leap
    /// "February 29 08:00" forward to March 1 08:00. (Every month
    /// except non-leap February has a 29th, so this is the only month
    /// where the rollover surfaces for `:29`.)
    ///
    /// Deterministic via a pinned February-2026 (non-leap) reference,
    /// rather than the wall-clock-dependent `nextTriggerDate()` the
    /// prior version relied on.
    func testMonthlyTwentyNinthRollsPastNonLeapFebruary() throws {
        let comps = try Send.parseCalendarRepeat("monthly:29:08:00")
        let calendar = Calendar(identifier: .gregorian)

        // From early Feb 2026 (non-leap; Feb has 28 days), "Feb 29"
        // does not exist, so the policy rolls forward to March 1.
        // `.strict` would instead skip to March 29 — asserting day == 1
        // pins that UN is NOT using strict.
        var refComps = DateComponents()
        refComps.year = 2026
        refComps.month = 2
        refComps.day = 5
        refComps.hour = 12
        refComps.minute = 0
        refComps.timeZone = TimeZone.current
        let ref = try XCTUnwrap(
            calendar.date(from: refComps), "Could not construct 2026-02-05")
        let rolled = try XCTUnwrap(
            calendar.nextDate(
                after: ref, matching: comps,
                matchingPolicy: .nextTimePreservingSmallerComponents),
            "Calendar returned nil for monthly:29 from Feb 5")
        let rolledComps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: rolled)
        XCTAssertEqual(rolledComps.month, 3,
                       "Expected rollover into March; got \(rolledComps)")
        XCTAssertEqual(rolledComps.day, 1,
                       "Expected rollover to the 1st (not a skip to the 29th); got \(rolledComps)")
        XCTAssertEqual(rolledComps.hour, 8)
        XCTAssertEqual(rolledComps.minute, 0)

        // Live: the real trigger agrees with the policy at the same
        // instant (tolerance absorbs the inter-call `now` delta; a
        // switch to `.strict` would move the fire by days).
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: comps, repeats: true)
        let unNext = try XCTUnwrap(
            trigger.nextTriggerDate(), "UN returned nil for monthly:29 trigger")
        let policyNext = try XCTUnwrap(
            Calendar.current.nextDate(
                after: Date(), matching: comps,
                matchingPolicy: .nextTimePreservingSmallerComponents),
            "Calendar returned nil for live monthly:29")
        XCTAssertEqual(
            unNext.timeIntervalSince(policyNext), 0, accuracy: 90,
            "UN's matching policy diverged from .nextTimePreservingSmallerComponents")
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
