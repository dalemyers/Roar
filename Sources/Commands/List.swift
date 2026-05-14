import ArgumentParser
import Darwin
import Foundation
import UserNotifications

/// `roar list` — print the notifications this app owns, both already
/// delivered (sitting in Notification Center) and pending (scheduled
/// via `--in` / `--at` but not yet fired).
///
/// Output is tab-separated, one notification per line, with no header
/// by default so the output composes cleanly with `awk -F'\t'` and
/// other line-oriented tools. Columns: identifier, status, time,
/// title, body. `time` is the delivery date for delivered
/// notifications and the next-fire date for pending requests.
struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List notifications belonging to this app."
    )

    @Flag(
        name: .long,
        help: "Show only delivered (already-fired) notifications. Mutually exclusive with --pending."
    )
    var delivered: Bool = false

    @Flag(
        name: .long,
        help: "Show only pending (scheduled-but-not-yet-fired) notifications. Mutually exclusive with --delivered."
    )
    var pending: Bool = false

    @Flag(
        name: .long,
        help: "Print a column header line before the listing."
    )
    var header: Bool = false

    /// Print the matching notifications and exit. Authorization is
    /// *not* required to enumerate — UN returns whatever this app has
    /// already produced regardless of current auth state.
    func run() async throws {
        if delivered, pending {
            throw ValidationError(
                "--delivered and --pending are mutually exclusive; omit both to see everything."
            )
        }
        let center = UNUserNotificationCenter.current()

        if header {
            print("ID\tSTATUS\tTIME\tTITLE\tBODY")
        }

        if !pending {
            // Default + --delivered case.
            let deliveredList = await center.deliveredNotifications()
            for n in deliveredList {
                print(Self.formatDelivered(n))
            }
        }
        if !delivered {
            // Default + --pending case.
            let pendingList = await center.pendingNotificationRequests()
            for r in pendingList {
                print(Self.formatPending(r))
            }
        }
        // Route through the shared exit chokepoint instead of a
        // direct `Darwin.exit(0)`. `roar list` is a read-only path
        // (no fire-and-forget XPC reply to flush), so the drain is
        // zero — but the test seam still applies, and a future
        // change that adds (say) "log how many lines were printed"
        // before exit will go through `CommandExit.hook` like every
        // other terminal path.
        await CommandExit.perform(CommandExit.Plan(drain: .zero, code: 0))
    }

    /// Render a `UNNotification` (already-delivered) as a tab-separated
    /// line. Newlines and tabs inside title/body are replaced with
    /// spaces so each notification stays on exactly one line — call
    /// sites that need multi-line text should use the request
    /// identifier to look the content up some other way.
    static func formatDelivered(_ notification: UNNotification) -> String {
        let date = Self.isoDate(notification.date)
        let content = notification.request.content
        return [
            notification.request.identifier,
            "delivered",
            date,
            Self.flatten(content.title),
            Self.flatten(content.body),
        ].joined(separator: "\t")
    }

    /// Render a pending `UNNotificationRequest` as a tab-separated
    /// line. The `time` column is the trigger's *next* fire date — for
    /// `UNTimeIntervalNotificationTrigger` we don't know when it was
    /// scheduled relative to `now`, so we report `nextTriggerDate()`
    /// which is the framework's authoritative answer. Returns
    /// `"(unscheduled)"` when the trigger reports no date — should not
    /// happen for triggers Roar produces but handles UN's
    /// `nil`-returning contract for completeness.
    static func formatPending(_ request: UNNotificationRequest) -> String {
        let when: String
        if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger,
           let next = trigger.nextTriggerDate() {
            when = Self.isoDate(next)
        } else if let trigger = request.trigger as? UNCalendarNotificationTrigger,
                  let next = trigger.nextTriggerDate() {
            when = Self.isoDate(next)
        } else {
            when = "(unscheduled)"
        }
        let content = request.content
        return [
            request.identifier,
            "pending",
            when,
            Self.flatten(content.title),
            Self.flatten(content.body),
        ].joined(separator: "\t")
    }

    /// Replace tabs, line-break-class characters, and any other C0
    /// control bytes (plus DEL) in a free-text field with single
    /// spaces. The tab-separated output format demands each cell
    /// stay on one line; UN happily lets users put newlines in
    /// `title`/`body` (we already trim them at send time for `body`,
    /// but `title` can still contain them, and an old delivered
    /// notification predating any trim could carry whatever the
    /// sender wrote).
    ///
    /// The full C0 sweep (U+0000..U+001F) plus U+007F is load-bearing
    /// for terminal safety: a notification title containing `\x1B[2J`
    /// (ESC + CSI Erase-in-Display) would otherwise wipe the screen
    /// of anyone running `roar list`, and `\x07` (BEL) would beep.
    /// Earlier this function scrubbed only HT/LF/VT/FF/CR plus the
    /// Unicode line separators, leaving the rest of the C0 range
    /// intact. Mapping every control byte to a space is conservative
    /// — they have no display value here.
    ///
    /// Also scrubbed: NEL (`U+0085`), LS (`U+2028`), PS (`U+2029`).
    /// Cocoa's text rendering treats them as line breaks, so a
    /// notification body containing `U+2028` would otherwise spill
    /// across rows in `pbcopy`-to-spreadsheet flows.
    static func flatten(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar -> Character in
            // C0 controls: U+0000..U+001F. Catches NUL, BEL, ESC, BS,
            // and the historical line-break shapes (LF, CR, VT, FF, HT).
            if scalar.value <= 0x1F { return " " }
            // U+007F (DEL) — not a C0 control but in the same
            // "non-printable ASCII" bucket; terminals interpret it.
            if scalar.value == 0x7F { return " " }
            // Cocoa-recognised line breaks above the ASCII range.
            switch scalar.value {
            case 0x85, 0x2028, 0x2029:
                return " "
            default:
                return Character(scalar)
            }
        })
    }

    /// ISO 8601 with second precision in the local time zone. The
    /// formatter is allocated per call rather than cached because
    /// `roar list` runs at human speed (tens of items at most) and a
    /// shared formatter would need synchronisation that is not worth
    /// the complexity here.
    static func isoDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
