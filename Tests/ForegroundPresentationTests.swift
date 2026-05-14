import XCTest
import ArgumentParser
import UserNotifications
@testable import roar

/// Pin the parser and userInfo round-trip for `--foreground-presentation`.
///
/// The flag is repeat-flag-style: each `--foreground-presentation`
/// occurrence carries a single option name. The serialised form
/// stored in userInfo under `roar.present.options` is still a
/// canonical comma-separated string (delegate compatibility); the
/// delegate parses it back into `UNNotificationPresentationOptions`
/// when `willPresent` fires. The serialised form must be deterministic
/// (sorted, deduped) so userInfo bytes don't drift, and the
/// deserialiser must reject malformed input by returning `nil` so the
/// delegate falls through to the default option set rather than
/// surfacing a silent zero-option presentation.
final class ForegroundPresentationTests: XCTestCase {

    // MARK: - parseForegroundPresentationOptions

    func testEmptyArrayReturnsNil() throws {
        // No flag occurrences = no user override. The delegate falls
        // back to its hardcoded default in `willPresent`.
        let parsed = try Send.parseForegroundPresentationOptions([])
        XCTAssertNil(parsed)
    }

    func testSingleOptionParses() throws {
        let parsed = try XCTUnwrap(
            Send.parseForegroundPresentationOptions(["banner"]))
        XCTAssertEqual(parsed.options, [.banner])
        XCTAssertEqual(parsed.serialized, "banner")
    }

    func testAllOptionsParse() throws {
        let parsed = try XCTUnwrap(
            Send.parseForegroundPresentationOptions(
                ["banner", "list", "sound", "badge"]))
        XCTAssertEqual(parsed.options, [.banner, .list, .sound, .badge])
        XCTAssertEqual(parsed.serialized, "banner,list,sound,badge")
    }

    func testCanonicalOrderIndependentOfInputOrder() throws {
        // `serialized` sorts names by their order in the option-name
        // table so userInfo bytes are deterministic regardless of how
        // the user typed the flag.
        let a = try XCTUnwrap(
            Send.parseForegroundPresentationOptions(["sound", "banner"]))
        let b = try XCTUnwrap(
            Send.parseForegroundPresentationOptions(["banner", "sound"]))
        XCTAssertEqual(a.serialized, b.serialized)
        XCTAssertEqual(a.serialized, "banner,sound")
    }

    func testWhitespaceAroundEntryTrimmed() throws {
        // Per-entry trimming protects against shell quoting accidents
        // like `--foreground-presentation ' banner '`.
        let parsed = try XCTUnwrap(
            Send.parseForegroundPresentationOptions([" banner ", "sound"]))
        XCTAssertEqual(parsed.options, [.banner, .sound])
        XCTAssertEqual(parsed.serialized, "banner,sound")
    }

    /// `--foreground-presentation none` is rejected at parse time so
    /// a `roar send --foreground-presentation none --badge-count 5`
    /// invocation surfaces the asymmetry between the send-side parser
    /// and the delegate-side deserializer (which refuses `none` for
    /// security). The previous behaviour accepted `none` at send time
    /// and silently upgraded to `banner+list+sound+badge` at display
    /// time — no diagnostic, no way for the caller to learn their
    /// preference was discarded. The error message must point users
    /// at `--interruption-level passive` (the supported way to
    /// suppress attention-grabbing presentation).
    func testNoneSentinelRejectedAtParseTime() {
        XCTAssertThrowsError(
            try Send.parseForegroundPresentationOptions(["none"])
        ) { error in
            XCTAssertTrue(
                error is ValidationError, "got \(type(of: error))")
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("--interruption-level passive"),
                "error must point at the supported alternative; got: \(message)"
            )
        }
    }

    /// `none` mixed with other names short-circuits the parser on
    /// the first `none` token. Pin that the message is still the
    /// `--interruption-level` alternative pointer rather than a
    /// generic "mixed" diagnostic.
    func testNoneMixedRejectedWithAlternativePointer() {
        XCTAssertThrowsError(
            try Send.parseForegroundPresentationOptions(["none", "banner"])
        ) { error in
            XCTAssertTrue(error is ValidationError)
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("--interruption-level passive"),
                "error must point at the supported alternative; got: \(message)"
            )
        }
    }

    func testEmptyStringEntryRejected() {
        // An explicit empty `--foreground-presentation ""` is an
        // operator error, not "no override" — surface it.
        XCTAssertThrowsError(
            try Send.parseForegroundPresentationOptions([""])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testWhitespaceOnlyEntryRejected() {
        XCTAssertThrowsError(
            try Send.parseForegroundPresentationOptions(["   "])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testUnknownNameRejected() {
        XCTAssertThrowsError(
            try Send.parseForegroundPresentationOptions(["banner", "alert"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testDeprecatedAlertRejected() {
        // `.alert` was deprecated in favour of `.banner`+`.list` on
        // macOS 11. Accepting it would let users type a value that
        // silently does nothing on modern OS versions.
        XCTAssertThrowsError(
            try Send.parseForegroundPresentationOptions(["alert"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    /// Comma-separated values within a single entry are no longer
    /// accepted: each `--foreground-presentation` flag carries one
    /// name, matching `--attachment`/`--action`/`--text-action`. A
    /// user who still types the old `banner,list` shape sees an
    /// unknown-option error rather than silent success.
    func testCommaSeparatedInSingleEntryNoLongerSupported() {
        XCTAssertThrowsError(
            try Send.parseForegroundPresentationOptions(["banner,list"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    func testDuplicateNameRejected() {
        XCTAssertThrowsError(
            try Send.parseForegroundPresentationOptions(["banner", "banner"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    /// `none` mixed with other names — both orderings still reject.
    func testNoneMixedWithOtherNamesRejected() {
        XCTAssertThrowsError(
            try Send.parseForegroundPresentationOptions(["none", "banner"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
        XCTAssertThrowsError(
            try Send.parseForegroundPresentationOptions(["banner", "none"])
        ) { XCTAssertTrue($0 is ValidationError, "got \(type(of: $0))") }
    }

    // MARK: - deserializeForegroundPresentationOptions (delegate side)

    func testDeserializeRoundTripsAllOptions() {
        let result = Send.deserializeForegroundPresentationOptions(
            "banner,list,sound,badge")
        XCTAssertEqual(result, [.banner, .list, .sound, .badge])
    }

    /// `none` is explicitly NOT honoured on the delegate side — see
    /// the `deserializeForegroundPresentationOptions` docstring for
    /// the security rationale. A same-bundle-id spoofer could post a
    /// notification with `roar.present.options = "none"` plus a
    /// `roar.exec.command` payload to create a visually-invisible
    /// but click-actionable surface. Returning `nil` here forces the
    /// delegate to fall back to the framework default
    /// (banner+list+sound+badge), so the click target is always
    /// visible to the user.
    func testDeserializeNoneReturnsNilForSecurity() {
        let result = Send.deserializeForegroundPresentationOptions("none")
        XCTAssertNil(
            result,
            "'none' must NOT deserialize to an empty option set — that "
            + "would let a malicious sender post invisible-but-clickable "
            + "notifications under our bundle id."
        )
    }

    func testDeserializeUnknownReturnsNil() {
        // The delegate uses `nil` as the signal to fall through to its
        // hardcoded default; a corrupted or future-roar value must NOT
        // silently produce a zero-option presentation.
        XCTAssertNil(Send.deserializeForegroundPresentationOptions("alert"))
        XCTAssertNil(Send.deserializeForegroundPresentationOptions("banner,oops"))
        XCTAssertNil(Send.deserializeForegroundPresentationOptions(""))
    }

    func testParseSerializeRoundTripIsStable() throws {
        // Parser canonicalises; deserialiser inverts. Together they
        // must round-trip for every recognised name combination —
        // otherwise userInfo bytes drift across roar invocations.
        //
        // `none` is deliberately excluded from this round-trip — the
        // parser rejects it at send time, and the deserialiser
        // refuses it for the security reason documented in
        // `testDeserializeNoneReturnsNilForSecurity`.
        let inputs: [[String]] = [
            ["banner"], ["list"], ["sound"], ["badge"],
            ["banner", "list"], ["banner", "sound"], ["list", "badge"],
            ["banner", "list", "sound", "badge"],
        ]
        for input in inputs {
            let parsed = try XCTUnwrap(
                Send.parseForegroundPresentationOptions(input))
            let deserialized = Send.deserializeForegroundPresentationOptions(
                parsed.serialized)
            XCTAssertEqual(
                deserialized, parsed.options,
                "round-trip failed for \(input)")
        }
    }

    /// Defence-in-depth pin: even though `--foreground-presentation
    /// none` is rejected at parse time (so no new build of roar
    /// writes `"none"` to userInfo), an *existing* notification
    /// posted by an older roar build — or by any other process under
    /// the same bundle id — may still carry the literal `"none"`
    /// string. The delegate must refuse to honour it on display so
    /// the click-actionable surface stays visible to the user. See
    /// `deserializeForegroundPresentationOptions`'s docstring for
    /// the full rationale.
    func testLegacyNoneStillRefusedByDelegate() {
        // The deserialiser is the security boundary; pass it the
        // literal string a legacy build would have written and
        // verify the fallback-to-default behaviour (nil result).
        XCTAssertNil(
            Send.deserializeForegroundPresentationOptions("none"),
            "'none' from legacy / spoofed userInfo must collapse to "
            + "the safe default at display time, not an invisible "
            + "presentation."
        )
    }

    // MARK: - Default option set unchanged

    func testDelegateDefaultUnchanged() {
        // Pin the default option set so a future change touching
        // `willPresent` is forced to update this test and reconsider
        // the surface area. The default carries `.list` and `.badge`
        // for the reasons spelled out in the delegate comment — both
        // are UN-era additions that NSUserNotificationCenter had no
        // equivalent for.
        XCTAssertEqual(
            RoarAppDelegate.defaultForegroundPresentationOptions,
            [.banner, .list, .sound, .badge]
        )
    }
}
