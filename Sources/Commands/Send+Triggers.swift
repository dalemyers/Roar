import ArgumentParser
import Foundation
import UserNotifications

/// Cached `--at` parsers, allocated once at module load and reused
/// across every call to `Send.tryParseScheduleDate`.
///
/// Each entry is a closure capturing a configured formatter and
/// returning the parsed `Date?`. Closures rather than a typed array
/// because `ISO8601DateFormatter` and `DateFormatter` don't share a
/// common date-parsing protocol; closure type-erasure is the
/// minimal-surface alternative to introducing one.
///
/// Order matters: more-specific shapes are listed first so a
/// `2026-12-31 17:00:00` string doesn't partially match the
/// `yyyy-MM-dd` shape and silently drop the time component.
///
/// The local-time shapes (3-6) capture `TimeZone.current` at module
/// initialisation. A CLI invocation's lifetime is short enough that
/// `TimeZone.current` is stable for the duration — moving a Mac
/// across timezones mid-invocation is not a workflow we model. The
/// previous per-call allocation re-read `TimeZone.current` on every
/// call, but the read happened during a single `roar send` so the
/// per-call freshness was already redundant.
private let scheduleDateFormatters: [(String) -> Date?] = {
    // Shape 1: ISO 8601 with zone.
    let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    // Shape 2: ISO 8601 with zone + fractional seconds.
    let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    // Shapes 3-6: local time without zone. Each gets its own
    // `DateFormatter` because `ISO8601DateFormatter` requires a
    // zone marker and won't parse the no-zone forms.
    let localFormats = [
        "yyyy-MM-dd'T'HH:mm:ss", // Shape 3
        "yyyy-MM-dd HH:mm:ss",   // Shape 4
        "yyyy-MM-dd HH:mm",      // Shape 5
        "yyyy-MM-dd",            // Shape 6
    ]
    let localFormatters: [DateFormatter] = localFormats.map { format in
        let df = DateFormatter()
        df.dateFormat = format
        // Pin the locale to en_US_POSIX so the grammar tokens
        // (yyyy/MM/dd) parse against ASCII digits and not the
        // user's preferred numeral set. Under `LANG=ar_SA.UTF-8`,
        // the default `DateFormatter` parses Arabic-Indic digits,
        // which would silently reject hand-typed ASCII timestamps.
        df.locale = Locale(identifier: "en_US_POSIX")
        // `TimeZone.current` is the whole point of the no-zone
        // shapes: the user typed a wall-clock time without
        // qualifying it, so we use the wall-clock time of the
        // system they're running roar on.
        df.timeZone = TimeZone.current
        // Strict parsing so `2026-12-31 25:00` doesn't parse as
        // "next day at 1am" via NSDateFormatter's lenient mode —
        // surface the error instead.
        df.isLenient = false
        return df
    }
    var parsers: [(String) -> Date?] = [
        { iso.date(from: $0) },
        { isoFrac.date(from: $0) },
    ]
    for formatter in localFormatters {
        parsers.append { formatter.date(from: $0) }
    }
    return parsers
}()

extension Send {
    /// Smallest delay the `--in` parser accepts. UN itself rejects
    /// zero/negative intervals with a runtime exception, and very small
    /// positive intervals (under ~1s) race the post-`add(_:)` exit
    /// drain on busy systems — the notification fires before the
    /// process even finishes handing off to usernoted, which surfaces
    /// as a "no notification posted" mystery to the user. 1 second is
    /// the lowest value where the schedule path is reliably distinct
    /// from the immediate-send path.
    static let minimumScheduleInterval: TimeInterval = 1.0

    /// Largest delay the `--in` / `--at` parsers accept. 365 days is
    /// already absurd for a CLI scheduler and serves as a typo guard:
    /// `--in 30000d` would otherwise schedule a notification for
    /// year ~2110 and the user would never know why nothing fired.
    static let maximumScheduleInterval: TimeInterval = 60 * 60 * 24 * 365

    /// Compile-once regex for the `--in` grammar:
    /// `<digits>(<dot><digits>)?<unit-char>` where the unit char is
    /// `s`/`m`/`h`/`d`. Pinning the grammar this tightly rejects
    /// shapes that `Double(_:)` would otherwise accept silently —
    /// hex floats (`0x1p3s`), scientific notation (`1e10s`), leading
    /// `+` signs, NaN/Inf literals — all of which violate the
    /// documented `<number><unit>` contract.
    static let scheduleIntervalPattern = /^([0-9]+(?:\.[0-9]+)?)([smhd])$/

    /// Resolve the user-supplied `--in` / `--at` / `--repeat` flags
    /// into a UN trigger, or `nil` if none was passed (immediate
    /// delivery). Enforces mutual exclusion and propagates parse
    /// failures as `ValidationError` so ArgumentParser formats them
    /// consistently with the rest of the `--option` failures.
    ///
    /// `--in` / `--at` produce non-repeating
    /// `UNTimeIntervalNotificationTrigger`s; `--repeat` produces a
    /// repeating `UNCalendarNotificationTrigger`. The three are
    /// mutually exclusive — combining "fire once in 5m" with "fire
    /// daily at 9am" has no coherent reading.
    ///
    /// `--at` is converted to "seconds from now" rather than decomposed
    /// into `DateComponents` for a calendar trigger: the calendar
    /// trigger silently truncates fractional seconds and uses
    /// whichever timezone the system's calendar is set to at *fire*
    /// time — both surprises would be load-bearing for users
    /// scheduling across DST transitions or with sub-second precision.
    /// An interval trigger fires at a wall-clock instant independent
    /// of calendar arithmetic. `--repeat` deliberately accepts the
    /// calendar semantics because recurring schedules want them
    /// (e.g. "9am every day" should keep meaning local 9am across DST).
    func resolveScheduleTrigger() throws -> UNNotificationTrigger? {
        try Self.validateScheduleMutualExclusion(
            scheduleIn: scheduleIn,
            scheduleAt: scheduleAt,
            scheduleRepeat: scheduleRepeat
        )
        if let scheduleIn {
            let interval = try Self.parseScheduleInterval(scheduleIn)
            return UNTimeIntervalNotificationTrigger(
                timeInterval: interval, repeats: false)
        }
        if let scheduleAt {
            let now = Date()
            let date = try Self.parseScheduleDate(scheduleAt, now: now)
            // `parseScheduleDate` already enforces
            // `interval >= minimumScheduleInterval`, so no clamp
            // here: the value the user typed is the value UN sees.
            // A previous version silently rewrote sub-floor values
            // to "1 second from now," which broke the "fires at the
            // timestamp I provided" contract for users who passed a
            // near-now `--at` from a script.
            let interval = date.timeIntervalSince(now)
            return UNTimeIntervalNotificationTrigger(
                timeInterval: interval, repeats: false)
        }
        if let scheduleRepeat {
            let components = try Self.parseCalendarRepeat(scheduleRepeat)
            return UNCalendarNotificationTrigger(
                dateMatching: components, repeats: true)
        }
        return nil
    }

    /// Reject `--in`, `--at`, `--repeat` set in any combination of two
    /// or more. Combining them has no sensible interpretation — they
    /// are alternative ways to say "fire later," not composable.
    /// Surface the mistake up-front rather than letting the
    /// last-wins precedence above silently pick one.
    /// All three parameters are required (no default values) so a
    /// future caller cannot silently skip the `--repeat` arm of the
    /// mutual-exclusion check by omitting the argument. Pass `nil`
    /// explicitly for any flag the caller is not exercising.
    static func validateScheduleMutualExclusion(
        scheduleIn: String?, scheduleAt: String?, scheduleRepeat: String?
    ) throws {
        var set: [String] = []
        if scheduleIn != nil { set.append("--in") }
        if scheduleAt != nil { set.append("--at") }
        if scheduleRepeat != nil { set.append("--repeat") }
        guard set.count >= 2 else { return }
        throw ValidationError(
            "\(set.joined(separator: ", ")) are mutually exclusive. Pick one."
        )
    }

    /// Map of `--repeat weekly:DAY:HH:MM` day-of-week tokens to the
    /// `Calendar` weekday integer the UN framework expects in
    /// `DateComponents.weekday`. Gregorian weekday numbering starts at
    /// 1 = Sunday — pin it explicitly so the table doesn't drift if a
    /// future refactor swaps calendars.
    static let weekdayTokens: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "wed": 4,
        "thu": 5, "fri": 6, "sat": 7,
    ]

    /// Parse a `--repeat` value into the `DateComponents` the
    /// `UNCalendarNotificationTrigger` consumes. Accepted shapes:
    ///
    /// * `hourly` — fire at minute 0 of every hour.
    /// * `daily:HH:MM` — fire every day at the given local HH:MM.
    /// * `weekly:DAY:HH:MM` — fire weekly on the given day-of-week
    ///   token (`mon`/`tue`/.../`sun`).
    /// * `monthly:D:HH:MM` — fire monthly on day-of-month D (1..31).
    ///
    /// HH is 0..23 (24-hour), MM is 0..59. All times are interpreted
    /// in the system's current local time zone — that's the UN
    /// framework's contract for `UNCalendarNotificationTrigger`, and
    /// users who type `daily:09:00` almost always mean "9am wherever I
    /// am" rather than 9am UTC.
    ///
    /// `monthly:31:HH:MM` (and `:29`/`:30`) is accepted at parse time,
    /// but beware: `UNCalendarNotificationTrigger` does NOT skip months
    /// that lack the requested day-of-month. Verified on macOS 26.5,
    /// UN resolves a non-existent date (e.g. "June 31") using the
    /// `.nextTimePreservingSmallerComponents` matching policy, which
    /// rolls the fire FORWARD to the 1st of the following month rather
    /// than skipping to the next 31-day month. So `monthly:31` during a
    /// 30-day month fires on the 1st, not the 31st; `monthly:29` in a
    /// non-leap February fires on March 1st. UN owns the recurrence
    /// after `add(_:)` (this CLI schedules-and-exits, see `Send.swift`),
    /// and the trigger API does not expose the matching policy, so this
    /// behavior cannot be corrected here — `Calendar.nextDate(...,
    /// matchingPolicy: .strict)` is what *would* skip, but UN won't use
    /// it. We accept the values rather than reject them (days 1..28 are
    /// always safe; 29..31 are useful when the user knows the rollover
    /// rule), and document the surprise here and in the `--repeat` help.
    ///
    /// The returned `DateComponents` carries an explicit Gregorian
    /// calendar. `UNCalendarNotificationTrigger` resolves the
    /// components against `components.calendar` (falling back to
    /// `Calendar.current` if unset) at *fire time*. The `weekdayTokens`
    /// table is hardcoded to Gregorian numbering (Sun=1..Sat=7), and
    /// the daily/monthly HH:MM bounds (0..23, 1..31) assume a
    /// Gregorian-style 24-hour day and month length. A user whose
    /// `Calendar.current` is set to Hebrew, Islamic, or Japanese
    /// would otherwise get the wrong day-of-week mapping or the wrong
    /// month boundary. Pin the calendar on the component itself so
    /// the schedule's meaning is independent of the system's
    /// preferred calendar.
    ///
    /// `nonisolated static` so tests can drive the grammar without
    /// constructing a trigger.
    ///
    /// - Parameter raw: The user-supplied `--repeat` value.
    /// - Returns: A `DateComponents` ready for
    ///   `UNCalendarNotificationTrigger(dateMatching:repeats:)`, with
    ///   `calendar` pinned to Gregorian.
    /// - Throws: `ValidationError` on any malformed shape.
    static func parseCalendarRepeat(_ raw: String) throws -> DateComponents {
        // Non-optional `requireNonBlank` overload: `raw` is already
        // non-optional, so the umbrella `String? -> String?` shape
        // would force a `!` unwrap with no upside. The dedicated
        // overload preserves the non-optional return type end-to-end.
        let trimmed = try SharedValidation.requireNonBlank(
            raw,
            flag: "--repeat",
            emptyAdvice:
                "Use 'hourly', 'daily:HH:MM', 'weekly:DAY:HH:MM', "
                + "or 'monthly:D:HH:MM'."
        )
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        // POSIX-locale lowercase: `.lowercased()` is locale-sensitive,
        // and under Turkish (`tr_TR.UTF-8`) uppercase `I` folds to
        // dotless `ı` rather than `i`. That makes `"FRI".lowercased()`
        // become `"frı"`, which misses the `"fri"` key in
        // `weekdayTokens` and `"HOURLY".lowercased()` become `"hourlı"`,
        // which misses `"hourly"`. The grammar is an ASCII protocol,
        // not a natural-language string, so we lowercase under
        // `en_US_POSIX` (ASCII rules) to keep the parser
        // locale-invariant.
        guard let period = parts.first?
            .lowercased(with: Locale(identifier: "en_US_POSIX")) else {
            throw ValidationError(
                "--repeat '\(raw)' is not a recognized pattern."
            )
        }
        // Seed every branch with a Gregorian-pinned `DateComponents` so
        // the trigger's interpretation of `weekday` / `hour` / `day`
        // doesn't drift with `Calendar.current` at fire time. See
        // method-level docstring for the full rationale.
        //
        // Every branch ALSO pins `components.second = 0` defensively.
        // `UNCalendarNotificationTrigger` resolves any field left
        // unspecified by matching "any valid value" — empirically the
        // framework today picks the first valid second (i.e. 0), which
        // matches the user-visible promise of "fires at HH:MM:00". A
        // future framework reinterpretation of the "match all
        // unspecified" rule (e.g. firing 60 times within the matching
        // minute) would silently break the contract. Pinning second 0
        // makes the schedule's intent explicit at the API boundary
        // rather than implicit in framework behaviour.
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.second = 0
        switch period {
        case "hourly":
            guard parts.count == 1 else {
                throw ValidationError(
                    "--repeat 'hourly' takes no arguments (got '\(raw)'). "
                    + "It fires at minute 0 of every hour."
                )
            }
            components.minute = 0
            return components
        case "daily":
            guard parts.count == 3 else {
                throw ValidationError(
                    "--repeat 'daily' requires 'daily:HH:MM' (got '\(raw)')."
                )
            }
            let (hour, minute) = try Self.parseRepeatTime(
                hh: parts[1], mm: parts[2], raw: raw)
            components.hour = hour
            components.minute = minute
            return components
        case "weekly":
            guard parts.count == 4 else {
                throw ValidationError(
                    "--repeat 'weekly' requires 'weekly:DAY:HH:MM' (got '\(raw)'). "
                    + "DAY ∈ mon|tue|wed|thu|fri|sat|sun."
                )
            }
            // POSIX-locale lowercase — see the rationale on `period`
            // above. Without this, `weekly:FRI:...` under `tr_TR.UTF-8`
            // becomes `frı` and misses the `fri` key.
            let dayToken = parts[1].lowercased(
                with: Locale(identifier: "en_US_POSIX"))
            guard let weekday = weekdayTokens[dayToken] else {
                throw ValidationError(
                    "--repeat '\(raw)' has unknown day '\(parts[1])'. "
                    + "Use one of: mon, tue, wed, thu, fri, sat, sun."
                )
            }
            let (hour, minute) = try Self.parseRepeatTime(
                hh: parts[2], mm: parts[3], raw: raw)
            components.weekday = weekday
            components.hour = hour
            components.minute = minute
            return components
        case "monthly":
            guard parts.count == 4 else {
                throw ValidationError(
                    "--repeat 'monthly' requires 'monthly:D:HH:MM' (got '\(raw)'). "
                    + "D is the day-of-month, 1..31."
                )
            }
            guard let day = Int(parts[1]), (1...31).contains(day) else {
                throw ValidationError(
                    "--repeat '\(raw)' has invalid day '\(parts[1])'. "
                    + "Use 1..31."
                )
            }
            let (hour, minute) = try Self.parseRepeatTime(
                hh: parts[2], mm: parts[3], raw: raw)
            components.day = day
            components.hour = hour
            components.minute = minute
            return components
        default:
            throw ValidationError(
                "--repeat '\(raw)' has unknown period '\(parts[0])'. "
                + "Use 'hourly', 'daily:HH:MM', 'weekly:DAY:HH:MM', or "
                + "'monthly:D:HH:MM'."
            )
        }
    }

    /// Shared HH:MM helper for `parseCalendarRepeat`. Rejects out-of-
    /// range or non-numeric values with a consistent diagnostic.
    private static func parseRepeatTime(
        hh: String, mm: String, raw: String
    ) throws -> (hour: Int, minute: Int) {
        guard let hour = Int(hh), (0...23).contains(hour) else {
            throw ValidationError(
                "--repeat '\(raw)' has invalid hour '\(hh)'. Use 0..23."
            )
        }
        guard let minute = Int(mm), (0...59).contains(minute) else {
            throw ValidationError(
                "--repeat '\(raw)' has invalid minute '\(mm)'. Use 0..59."
            )
        }
        return (hour: hour, minute: minute)
    }

    /// Parse `<number><unit>` (e.g. `30s`, `5m`, `2h`, `1d`) into
    /// seconds. Whitespace is trimmed; the unit suffix is required and
    /// is one of `s`/`m`/`h`/`d` (singular, lowercase). The numeric
    /// portion accepts fractional values (`1.5h`) so users don't have
    /// to convert to seconds in their head for "90 minutes."
    ///
    /// `nonisolated static` so tests can exercise parsing without
    /// driving ArgumentParser.
    ///
    /// - Parameter raw: The user-supplied `--in` value.
    /// - Returns: Number of seconds, guaranteed `>= minimumScheduleInterval`
    ///   and finite.
    /// - Throws: `ValidationError` on empty input, missing/unknown
    ///   unit, non-finite or non-positive numeric portion, or values
    ///   below the minimum.
    static func parseScheduleInterval(_ raw: String) throws -> TimeInterval {
        // Non-optional `requireNonBlank` overload — see
        // `parseCalendarRepeat` for the rationale.
        let trimmed = try SharedValidation.requireNonBlank(
            raw,
            flag: "--in",
            emptyAdvice: "Use a value like 30s, 5m, 2h, or 1d."
        )
        guard let match = try? scheduleIntervalPattern.wholeMatch(in: trimmed) else {
            throw ValidationError(
                "--in '\(raw)' is not a recognized duration. Expected "
                + "<number><unit> where unit is s|m|h|d (e.g. 30s, 5m, 1.5h, 2d). "
                + "Hex / scientific notation / signed forms are not accepted."
            )
        }
        let numericPart = String(match.1)
        let unit = match.2
        let multiplier: TimeInterval
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 60 * 60
        case "d": multiplier = 60 * 60 * 24
        default:
            // Defensive: the regex's character class already enforces
            // one of s/m/h/d, so this branch is unreachable. Spelled
            // out so a future grammar widening doesn't silently
            // resolve to multiplier=0.
            throw ValidationError(
                "--in '\(raw)' has an unsupported unit '\(unit)'."
            )
        }
        // The regex guarantees `numericPart` is `[0-9]+(\.[0-9]+)?` —
        // `Double(_:)` will accept and produce a finite value. Still
        // wrap defensively in case a future locale-aware refactor
        // changes that.
        guard let value = Double(numericPart), value.isFinite else {
            throw ValidationError(
                "--in '\(raw)' has a non-numeric value '\(numericPart)'."
            )
        }
        let seconds = value * multiplier
        guard seconds >= minimumScheduleInterval else {
            throw ValidationError(
                "--in '\(raw)' resolves to \(seconds)s, below the "
                + "\(minimumScheduleInterval)s minimum. Use a longer delay, "
                + "or omit --in for immediate delivery."
            )
        }
        guard seconds <= maximumScheduleInterval else {
            throw ValidationError(
                "--in '\(raw)' resolves to \(seconds)s, above the "
                + "\(maximumScheduleInterval)s (~365 days) maximum. Pick a "
                + "shorter delay; cron / launchd / a daemon is a better tool "
                + "than a CLI for long-range scheduling."
            )
        }
        return seconds
    }

    /// Parse a `--at` timestamp into a `Date`.
    ///
    /// Accepted shapes, tried in order:
    ///
    /// 1. ISO 8601 with timezone (`2026-12-31T17:00:00Z`,
    ///    `2026-12-31T17:00:00+01:00`). The unambiguous form — no
    ///    locale or system-timezone interpretation needed.
    /// 2. ISO 8601 with timezone and fractional seconds
    ///    (`2026-12-31T17:00:00.123Z`). Some upstream tools emit
    ///    this shape; accepting it spares users a rounding step.
    /// 3. Local time, T-separator, no zone
    ///    (`2026-12-31T17:00:00`) — interpreted in the system's
    ///    `TimeZone.current`.
    /// 4. Local time, space-separator, no zone
    ///    (`2026-12-31 17:00:00`) — the "human-typed" shape; the
    ///    space replaces the `T` separator. Common in shell
    ///    invocations and the output of `date '+%F %T'`.
    /// 5. Local time, no seconds (`2026-12-31 17:00`) — convenience
    ///    for hand-typed schedules ("8pm tomorrow"). Treats seconds
    ///    as zero.
    /// 6. Date-only (`2026-12-31`) — midnight local time on the
    ///    given date.
    ///
    /// Shapes 3-6 are interpreted in the local timezone; users
    /// scheduling across DST transitions or sharing scripts across
    /// machines should prefer shape 1/2.
    ///
    /// Rejects two distinct misuse shapes with distinct messages:
    ///
    /// * Strict past (`date < now`) — UN would fire it immediately,
    ///   which contradicts the "scheduled" framing and is almost
    ///   always a typo'd year.
    /// * Near-future (`date - now < minimumScheduleInterval`) — the
    ///   resolver used to silently rewrite these to "1 second from
    ///   now" via `max(interval, minimumScheduleInterval)`, which
    ///   broke the user-visible contract that the notification fires
    ///   at the supplied timestamp.
    ///
    /// `nonisolated static` so tests can inject a fixed `now`.
    ///
    /// - Parameters:
    ///   - raw: The user-supplied `--at` value.
    ///   - now: Reference instant for the past/near-past check.
    ///     Injected so tests can pin a clock.
    /// - Returns: The parsed `Date`, guaranteed
    ///   `>= now + minimumScheduleInterval`.
    /// - Throws: `ValidationError` on empty input, parse failure, a
    ///   date in the past, or a date too close to `now`.
    static func parseScheduleDate(_ raw: String, now: Date) throws -> Date {
        // Non-optional `requireNonBlank` overload — see
        // `parseCalendarRepeat` for the rationale.
        let trimmed = try SharedValidation.requireNonBlank(
            raw,
            flag: "--at",
            emptyAdvice: "Use a timestamp like 2026-12-31T17:00:00Z or 2026-12-31 17:00."
        )
        if let parsed = Self.tryParseScheduleDate(trimmed) {
            try Self.rejectPastOrNearFutureDate(parsed, now: now, raw: raw)
            return parsed
        }
        throw ValidationError(
            "--at '\(raw)' is not a recognised timestamp. Accepted forms: "
            + "ISO 8601 with zone ('2026-12-31T17:00:00Z' / "
            + "'2026-12-31T17:00:00+01:00'), local time without zone "
            + "('2026-12-31T17:00:00' or '2026-12-31 17:00:00' or "
            + "'2026-12-31 17:00'), or date-only at local midnight "
            + "('2026-12-31')."
        )
    }

    /// Try every accepted `--at` shape until one parses. Returns
    /// `nil` if none match; the caller raises a `ValidationError`
    /// with the full grammar hint. Split from `parseScheduleDate`
    /// so the past/near-future check stays a single call site —
    /// no matter which shape matched, the verdict on "is this far
    /// enough in the future?" runs once.
    ///
    /// The formatters are file-scope caches (`scheduleDateFormatters`)
    /// rather than per-call allocations: each `--at` invocation
    /// would otherwise build 2 `ISO8601DateFormatter`s + 4
    /// `DateFormatter`s for a single hand-typed timestamp, and
    /// allocating six full formatter graphs is a real cost for a
    /// pure parser. The cached formatters are configured once and
    /// only read after that, so they are safe to share across
    /// invocations.
    ///
    /// Local-time formatters pin `Locale(identifier: "en_US_POSIX")`
    /// so a non-Gregorian system locale (Hebrew, Islamic, Japanese
    /// calendar) doesn't redirect the year/month parser; they
    /// inherit `TimeZone.current` deliberately on every call (the
    /// timezone is captured at the formatter's instantiation, which
    /// is acceptable for short-lived CLI invocations — see
    /// `scheduleDateFormatters` for the lifecycle note).
    ///
    /// `nonisolated static` so tests can drive shape coverage
    /// directly.
    private static func tryParseScheduleDate(_ trimmed: String) -> Date? {
        for parse in scheduleDateFormatters {
            if let date = parse(trimmed) { return date }
        }
        return nil
    }

    /// Shared past/near-future check for the two ISO8601 parse
    /// branches. Pulled into a helper so the message text stays
    /// consistent across "with fractional seconds" and "without"
    /// paths, and so the two distinct failure modes have distinct
    /// (non-confusable) diagnostics.
    private static func rejectPastOrNearFutureDate(
        _ date: Date, now: Date, raw: String
    ) throws {
        if date < now {
            throw ValidationError(
                "--at '\(raw)' is in the past. macOS would fire it "
                + "immediately, which contradicts the 'scheduled' intent; "
                + "use a future timestamp or omit --at for immediate delivery."
            )
        }
        // `>= now` but still within `minimumScheduleInterval`. The
        // resolver used to clamp these up to the floor; that broke
        // the "fires at the timestamp I provided" contract, so reject
        // with a message that names the floor explicitly.
        let interval = date.timeIntervalSince(now)
        guard interval >= minimumScheduleInterval else {
            throw ValidationError(
                "--at '\(raw)' is too close to now (\(interval)s away); "
                + "must be at least \(minimumScheduleInterval)s in the "
                + "future. Use a later timestamp, or omit --at for "
                + "immediate delivery."
            )
        }
    }
}
