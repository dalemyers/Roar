import XCTest
import ArgumentParser
@testable import roar

/// Tests for the shared `--json` output mode.
///
/// Two distinct contracts are pinned here:
///
/// 1. **Future-proofing.** Every subcommand registered on `Roar`
///    must accept `--json`. Iterating `Roar.configuration.subcommands`
///    rather than hard-coding the list means a new subcommand
///    added later — without remembering to `@OptionGroup
///    OutputOptions` — fails this test instead of silently
///    shipping a subcommand whose output can't be JSON-mode'd.
/// 2. **Schema stability.** The JSON shape per subcommand is a
///    scripting ABI: shapes can gain fields, but renames and
///    removals are major-version breaks. Per-shape tests pin
///    the exact emitted bytes so a regression that renames
///    `delivered_cleared` (say) to `clearedDelivered` fails
///    here before it ships.
final class OutputModeTests: XCTestCase {

    // MARK: - Future-proofing: every subcommand has --json

    /// Iterate `Roar.configuration.subcommands` and assert each
    /// declares a `--json` flag. The check is against
    /// `helpMessage()` because that's the user-visible surface and
    /// catches both the canonical `@OptionGroup OutputOptions`
    /// pattern and any future hand-rolled equivalent.
    ///
    /// If you add a new subcommand and this test fails: add
    /// `@OptionGroup var output: OutputOptions` to the new
    /// command's struct and route its stdout through the same
    /// `output.json ? encodeJSON(...) : <text>` shape every other
    /// subcommand uses.
    func testEverySubcommandHasJSONFlag() {
        let subcommandTypes = Roar.configuration.subcommands
        XCTAssertFalse(
            subcommandTypes.isEmpty,
            "Sanity: Roar must register at least one subcommand"
        )
        for cmdType in subcommandTypes {
            let name = cmdType.configuration.commandName ?? "<unknown>"
            let help = cmdType.helpMessage()
            XCTAssertTrue(
                help.contains("--json"),
                "Subcommand `roar \(name)` is missing the `--json` flag. "
                + "Add `@OptionGroup var output: OutputOptions` and route stdout "
                + "through `encodeJSON(...)` when `output.json` is set. "
                + "See OutputOptions.swift for the pattern."
            )
        }
    }

    /// Sanity: a subcommand without `--json` would actually fail
    /// the test above. This guard verifies the matching is on the
    /// flag itself and not on some incidental substring of
    /// `helpMessage()`. Constructs a throwaway `ParsableCommand`
    /// with no flags and confirms the assertion fires.
    func testFutureProofingTestActuallyDetectsMissingFlag() {
        struct FakeSubcommandWithoutJSON: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "fake",
                abstract: "Test fixture; not registered on Roar."
            )
        }
        XCTAssertFalse(
            FakeSubcommandWithoutJSON.helpMessage().contains("--json"),
            "Sanity: a subcommand with no flags must not appear to support --json"
        )
    }

    // MARK: - JSON encoder behaviour

    /// `encodeJSON` emits compact, single-line JSON with sorted
    /// keys. Compact so the output composes with `jq` and line-
    /// oriented shell tools; sorted keys so the byte output is
    /// deterministic across runs (test golden values, byte-equal
    /// `diff` of two invocations, etc.).
    func testEncodeJSONIsCompactAndSorted() {
        struct Sample: Encodable {
            let zebra: Int
            let alpha: String
        }
        let json = encodeJSON(Sample(zebra: 1, alpha: "hi"))
        XCTAssertEqual(json, "{\"alpha\":\"hi\",\"zebra\":1}")
        XCTAssertFalse(json.contains("\n"),
                       "encodeJSON must be single-line; got:\n\(json)")
    }

    // MARK: - List

    func testListJSONEntryShapeDelivered() {
        // The Foundation `UNNotification` class is sealed (no
        // public initialiser), so this test exercises the JSON
        // schema directly via the `JSONEntry` value the
        // formatter would produce. The full integration with
        // `formatDelivered`/`formatPending` is covered by the
        // ListFormattingTests in the existing test surface.
        let entry = List.JSONEntry(
            bucket: "delivered",
            when: "2026-05-15T12:34:56Z",
            identifier: "build-status",
            title: "Build complete",
            body: "All green"
        )
        let json = encodeJSON([entry])
        XCTAssertEqual(
            json,
            "[{\"body\":\"All green\",\"bucket\":\"delivered\","
            + "\"identifier\":\"build-status\","
            + "\"title\":\"Build complete\","
            + "\"when\":\"2026-05-15T12:34:56Z\"}]"
        )
    }

    func testListJSONEntryRendersNullWhenForUnresolved() {
        let entry = List.JSONEntry(
            bucket: "pending",
            when: nil,
            identifier: "weird-trigger",
            title: "t", body: "b"
        )
        let json = encodeJSON(entry)
        XCTAssertTrue(json.contains("\"when\":null"),
                      "Unresolved fire time should serialise as JSON null; got \(json)")
    }

    // MARK: - Settings

    func testSettingsJSONShape() throws {
        // Drive the JSON-shape encoder directly to avoid the
        // sealed `UNNotificationSettings` problem. The shape
        // exists as a typed value precisely so tests can pin the
        // wire format independent of the framework type.
        let shape = Settings.JSONShape(
            authorizationStatus: "authorized",
            alertSetting: "enabled",
            alertStyle: "banner",
            soundSetting: "enabled",
            lockScreenSetting: "enabled",
            notificationCenterSetting: "enabled",
            criticalAlertSetting: "not-supported",
            showPreviewsSetting: "always",
            timeSensitiveSetting: "enabled",
            scheduledDeliverySetting: "disabled",
            directMessagesSetting: "not-supported",
            providesAppNotificationSettings: false
        )
        let json = encodeJSON(shape)
        // Pin a few representative fields; full byte-equality is
        // brittle when the test reads more like a checksum than
        // documentation. The presence + spelling of the
        // user-facing keys is the schema; the values are pass-
        // through tokens already pinned in SettingsFormatTests.
        XCTAssertTrue(json.contains("\"authorization-status\":\"authorized\""),
                      "Missing authorization-status key; got \(json)")
        XCTAssertTrue(json.contains("\"alert-style\":\"banner\""),
                      "Missing alert-style key; got \(json)")
        XCTAssertTrue(json.contains("\"provides-app-notification-settings\":false"),
                      "Missing or wrong-typed provides-app-notification-settings; got \(json)")
    }

    // MARK: - Dismiss

    func testDismissJSONShape() {
        let shape = Dismiss.JSONShape(
            requested: ["foo", "bar", "foo"],
            unknown: ["bar"]
        )
        let json = encodeJSON(shape)
        XCTAssertEqual(
            json,
            "{\"requested\":[\"foo\",\"bar\",\"foo\"],\"unknown\":[\"bar\"]}"
        )
    }

    func testDismissJSONEmptyUnknowns() {
        let shape = Dismiss.JSONShape(
            requested: ["only-one"],
            unknown: []
        )
        let json = encodeJSON(shape)
        XCTAssertEqual(json, "{\"requested\":[\"only-one\"],\"unknown\":[]}")
    }

    // MARK: - Clear

    func testClearJSONShapeAll() {
        let shape = Clear.JSONShape(
            deliveredCleared: true,
            pendingCleared: true,
            categoriesPruned: false
        )
        let json = encodeJSON(shape)
        XCTAssertEqual(
            json,
            "{\"categories_pruned\":false,"
            + "\"delivered_cleared\":true,"
            + "\"pending_cleared\":true}"
        )
    }

    func testClearJSONShapePendingOnly() {
        let shape = Clear.JSONShape(
            deliveredCleared: false,
            pendingCleared: true,
            categoriesPruned: false
        )
        let json = encodeJSON(shape)
        XCTAssertTrue(json.contains("\"delivered_cleared\":false"))
        XCTAssertTrue(json.contains("\"pending_cleared\":true"))
    }

    // MARK: - Send (non-wait)

    func testSendPostedJSONShape() {
        let shape = Send.JSONPostedShape(
            identifier: "abc-123",
            posted: true
        )
        let json = encodeJSON(shape)
        XCTAssertEqual(json, "{\"identifier\":\"abc-123\",\"posted\":true}")
    }

    // MARK: - Send --wait

    func testSendWaitJSONShapeDefaultClick() {
        let shape = Send.WaitJSONShape(
            outcome: "click",
            action: "default",
            text: nil
        )
        let json = encodeJSON(shape)
        XCTAssertEqual(
            json,
            "{\"action\":\"default\",\"outcome\":\"click\",\"text\":null}"
        )
    }

    func testSendWaitJSONShapeCustomAction() {
        let shape = Send.WaitJSONShape(
            outcome: "click",
            action: "approve",
            text: nil
        )
        let json = encodeJSON(shape)
        XCTAssertEqual(
            json,
            "{\"action\":\"approve\",\"outcome\":\"click\",\"text\":null}"
        )
    }

    func testSendWaitJSONShapeTextAction() {
        let shape = Send.WaitJSONShape(
            outcome: "click",
            action: "reply",
            text: "Hello\nworld"
        )
        let json = encodeJSON(shape)
        // JSON string escapes the embedded newline as `\n` (six
        // literal characters: backslash + n), which is the whole
        // point of using JSON for this — the text protocol relied
        // on "read to EOF" to survive embedded newlines.
        XCTAssertEqual(
            json,
            "{\"action\":\"reply\","
            + "\"outcome\":\"click\","
            + "\"text\":\"Hello\\nworld\"}"
        )
    }

    func testSendWaitJSONShapeDismiss() {
        let shape = Send.WaitJSONShape(
            outcome: "dismiss",
            action: "dismiss",
            text: nil
        )
        let json = encodeJSON(shape)
        XCTAssertEqual(
            json,
            "{\"action\":\"dismiss\",\"outcome\":\"dismiss\",\"text\":null}"
        )
    }

    func testSendWaitJSONShapeTimeout() {
        let shape = Send.WaitJSONShape(
            outcome: "timeout",
            action: "timeout",
            text: nil
        )
        let json = encodeJSON(shape)
        XCTAssertEqual(
            json,
            "{\"action\":\"timeout\",\"outcome\":\"timeout\",\"text\":null}"
        )
    }

    // MARK: - --json parses correctly on each subcommand

    /// Smoke test: each subcommand accepts `--json` without
    /// rejecting it as an unknown option. Parses (and discards)
    /// the resulting command struct just to prove the flag goes
    /// through ArgumentParser cleanly. Distinct from
    /// `testEverySubcommandHasJSONFlag` (which checks the help
    /// text) because a flag declared but not actually wired into
    /// the option group would pass the help-text check but fail
    /// here.
    func testJSONFlagParsesOnEachSubcommand() throws {
        // Each subcommand has different required args; pass the
        // minimum each needs alongside `--json` and verify parse
        // succeeds. Dismiss requires an identifier; Send doesn't
        // strictly require any flag at the parse stage (run-time
        // body validation happens later).
        XCTAssertNoThrow(try Send.parse(["--json"]))
        XCTAssertNoThrow(try List.parse(["--json"]))
        XCTAssertNoThrow(try Dismiss.parse(["--json", "some-id"]))
        XCTAssertNoThrow(try Clear.parse(["--json"]))
        XCTAssertNoThrow(try Settings.parse(["--json"]))
    }
}
