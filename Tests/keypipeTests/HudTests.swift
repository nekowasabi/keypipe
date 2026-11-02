import XCTest

@testable import keypipe

/// In-process proof for SPEC-hud H1-H8. The scripted feeds in
/// `.claude/skills/verify-keypipe-rules/verify.sh` prove the same items through the binary;
/// these tests prove the pill records, labels and gates directly.
final class HudTests: XCTestCase {
    private func drive(
        _ keys: String, config: KeypipeConfig, desktop: FakeDesktop,
        shell: @escaping (String, String, [String: String], TimeInterval) -> ShellOutcome = {
            _, input, _, _ in .exited(0, stdout: input.uppercased())
        },
        background: @escaping (Job) -> Bool = { _ in true }
    ) -> [String] {
        var lines: [String] = []
        var engine = Engine(
            config: config, desktop: desktop, shell: shell, emit: { lines.append($0) },
            background: background)
        for character in keys {
            desktop.key(character)
            engine.key(character)
        }
        return lines
    }

    private func textField(_ fieldText: String = "hello") -> FakeDesktop {
        FakeDesktop(focus: .text, fieldText: fieldText)
    }

    private func hudLines(_ lines: [String]) -> [String] {
        lines.filter { $0.hasPrefix("keypipe hud ") }
    }

    func testDeliveredAndReplacedShowOneOkPillAfterTheSpinner() {
        let replaced = Rule(
            trigger: "@@@", when: When(focus: .textField), transform: Guarded(primary: "up"),
            output: Guarded(primary: .builtin(.replaceInput)))
        let desktop = textField()
        let lines = drive("@@@", config: KeypipeConfig(rules: [replaced]), desktop: desktop)
        XCTAssertEqual(desktop.busy, [true, false])
        XCTAssertEqual(desktop.fired.count, 1)
        XCTAssertEqual(desktop.fired.first?.status, .ok)
        XCTAssertEqual(desktop.fired.first?.trigger, .text("@@@"))
        XCTAssertNil(desktop.fired.first?.stage)
        XCTAssertNil(desktop.fired.first?.icon)
        XCTAssertEqual(
            hudLines(lines), [#"keypipe hud @@@ ok "@@@ → replaceInput" none"#])
        XCTAssertEqual(desktop.fieldText, "HELLO")

        let delivered = Rule(trigger: "@@@", output: Guarded(primary: .shell("true")))
        let any = textField()
        let lines2 = drive("@@@", config: KeypipeConfig(rules: [delivered]), desktop: any)
        XCTAssertEqual(any.fired.count, 1)
        XCTAssertEqual(
            hudLines(lines2), [#"keypipe hud @@@ ok "@@@ → true" none"#])
    }

    func testFailedAfterBusyShowsFailedPillWithStageAndKeepsNotify() {
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField), transform: Guarded(primary: "exit 3"),
            output: Guarded(primary: .builtin(.replaceInput)))
        let desktop = textField()
        let lines = drive(
            "@@@", config: KeypipeConfig(rules: [rule]), desktop: desktop
        ) { _, _, _, _ in .exited(3, stdout: "ignored") }
        XCTAssertEqual(desktop.busy, [true, false])
        XCTAssertEqual(desktop.fired.count, 1)
        XCTAssertEqual(desktop.fired.first?.status, .failed)
        XCTAssertEqual(desktop.fired.first?.stage, "transform")
        XCTAssertEqual(desktop.fired.first?.label, "@@@ → replaceInput")
        XCTAssertEqual(
            hudLines(lines), [#"keypipe hud @@@ failed "@@@ → replaceInput" none"#])
        XCTAssertTrue(lines.contains(#"keypipe apply notify "@@@ transform failed: exit 3""#))
        XCTAssertEqual(desktop.fieldText, "hello")
    }

    func testFailedSpawnAfterBusyShowsFailedPill() {
        let rule = Rule(
            trigger: "&&&", when: When(focus: .textField),
            output: Guarded(primary: .shell(ShellOutput(script: "curl", background: true))))
        let desktop = FakeDesktop(app: "editor", focus: .text, fieldText: "note")
        let lines = drive(
            "&&&", config: KeypipeConfig(rules: [rule]), desktop: desktop,
            background: { _ in false })
        XCTAssertEqual(desktop.busy, [true, false])
        XCTAssertEqual(desktop.fired.count, 1)
        XCTAssertEqual(desktop.fired.first?.status, .failed)
        XCTAssertEqual(desktop.fired.first?.stage, "spawn")
        XCTAssertEqual(hudLines(lines).count, 1)
        XCTAssertTrue(hudLines(lines).first?.contains("failed") ?? false)
    }

    func testStartedShowsOneStartedPill() {
        let rule = Rule(
            trigger: "&&&", when: When(focus: .textField),
            output: Guarded(primary: .shell(ShellOutput(script: "curl", background: true))))
        let desktop = FakeDesktop(app: "editor", focus: .text, fieldText: "note")
        let lines = drive("&&&", config: KeypipeConfig(rules: [rule]), desktop: desktop)
        XCTAssertEqual(desktop.fired.count, 1)
        XCTAssertEqual(desktop.fired.first?.status, .started)
        XCTAssertNil(desktop.fired.first?.stage)
        XCTAssertEqual(
            hudLines(lines), [#"keypipe hud &&& started "&&& → curl" none"#])
    }

    func testBlockedNoMatchUnreadableAndNoInputShowNothing() {
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField), transform: Guarded(primary: "up"),
            output: Guarded(primary: .builtin(.replaceInput)))
        let config = KeypipeConfig(rules: [rule])
        let blocked: [FakeDesktop] = [
            FakeDesktop(app: "term", focus: .terminal, fieldText: "pane"),
            FakeDesktop(focus: .nothing),
            FakeDesktop(focus: .composing, fieldText: "hello"),
            FakeDesktop(focus: .text, fieldText: "hello", secure: true),
        ]
        let denyAll = KeypipeConfig(
            rules: [rule], deny: [Conditions([Term(fact: .app, globs: ["*"])])])
        for desktop in blocked {
            let lines = drive("@@@", config: config, desktop: desktop)
            XCTAssertEqual(desktop.fired, [], "no pill off the busy path")
            XCTAssertEqual(desktop.busy, [], "no spinner either")
            XCTAssertEqual(hudLines(lines), [])
        }
        let denied = FakeDesktop(app: "com.example.app", focus: .text, fieldText: "hello")
        let denyLines = drive("@@@", config: denyAll, desktop: denied)
        XCTAssertEqual(denied.fired, [])
        XCTAssertEqual(denied.busy, [])
        XCTAssertEqual(hudLines(denyLines), [])
        let unreadable = FakeDesktop(
            focus: .text, fieldText: "hello", facts: [.url: .unreadable("timeout")])
        let urlRule = Rule(
            trigger: "@@@",
            when: When(focus: .textField, facts: [Term(fact: .url, globs: ["*"])]),
            output: Guarded(primary: .builtin(.replaceInput)))
        let unreadLines = drive("@@@", config: KeypipeConfig(rules: [urlRule]), desktop: unreadable)
        XCTAssertEqual(unreadable.fired, [])
        XCTAssertEqual(hudLines(unreadLines), [])
        // The field vanishes under the rewrite, so the erase finds nothing to carry on
        // with: noInput hides the spinner with no pill.
        let gone = FakeDesktop(
            focus: .text, fieldText: "hello", ignoresBackspace: true, goneAfterErase: true)
        let goneLines = drive("@@@", config: config, desktop: gone)
        XCTAssertEqual(gone.busy, [true, false], "the spinner still hides")
        XCTAssertEqual(gone.fired, [], "a vanished field reports no pill")
        XCTAssertEqual(hudLines(goneLines), [])
    }

    func testLabelPrefersNameThenScriptThenSinkAndCollapsesWhitespace() {
        func label(_ rule: Rule) -> String {
            firedLabel(trigger: "@@@", rule: rule)
        }
        XCTAssertEqual(
            label(
                Rule(
                    trigger: "@@@", when: When(focus: .textField),
                    output: Guarded(primary: .builtin(.replaceInput)), name: "My Rule")),
            "@@@ → My Rule")
        XCTAssertEqual(
            label(
                Rule(
                    trigger: "@@@", when: When(focus: .textField),
                    output: Guarded(primary: .builtin(.replaceInput)), name: "Line1\nLine2")),
            "@@@ → Line1 Line2")
        let long = "true abcdefghijklmnopqrstuvwxyz-0123456789-EXTRA"
        XCTAssertEqual(long.count, 48)
        XCTAssertEqual(
            label(
                Rule(
                    trigger: "@@@",
                    output: Guarded(primary: .shell(ShellOutput(script: long))))),
            "@@@ → true abcdefghijklmnopqrstuvwxyz-01234567")
        XCTAssertEqual(
            label(Rule(trigger: "@@@", output: Guarded(primary: .builtin(.replaceInput)))),
            "@@@ → replaceInput")
        XCTAssertEqual(
            label(
                Rule(
                    trigger: "@@@", transform: Guarded(primary: "printf CANARY-9f3"),
                    output: Guarded(primary: .builtin(.replaceInput)))),
            "@@@ → replaceInput",
            "transform stdout never reaches the pill")
    }

    func testIconRidesTheEventAndTheTranscriptVerbatim() {
        for icon in ["/Applications/TextEdit.app", "/tmp/keypipe-icon.png", "🚀"] {
            let rule = Rule(
                trigger: "@@@", when: When(focus: .textField),
                transform: Guarded(primary: "up"),
                output: Guarded(primary: .builtin(.replaceInput)), icon: icon)
            let desktop = textField()
            let lines = drive("@@@", config: KeypipeConfig(rules: [rule]), desktop: desktop)
            XCTAssertEqual(desktop.fired.first?.icon, icon)
            XCTAssertEqual(
                hudLines(lines),
                [#"keypipe hud @@@ ok "@@@ → replaceInput" \#(jsonString(icon))"#])
        }
        let plain = Rule(
            trigger: "@@@", when: When(focus: .textField), transform: Guarded(primary: "up"),
            output: Guarded(primary: .builtin(.replaceInput)))
        let desktop = textField()
        let lines = drive("@@@", config: KeypipeConfig(rules: [plain]), desktop: desktop)
        XCTAssertNil(desktop.fired.first?.icon)
        XCTAssertEqual(
            hudLines(lines), [#"keypipe hud @@@ ok "@@@ → replaceInput" none"#])
    }

    func testHudFalseShowsNoPillAndEmitsNoLine() {
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField), transform: Guarded(primary: "up"),
            output: Guarded(primary: .builtin(.replaceInput)))
        let desktop = textField()
        let lines = drive("@@@", config: KeypipeConfig(rules: [rule], hud: false), desktop: desktop)
        XCTAssertTrue(lines.contains("keypipe matched @@@ rule 0"))
        XCTAssertEqual(desktop.busy, [true, false], "the spinner is untouched by the flag")
        XCTAssertEqual(desktop.fired, [])
        XCTAssertEqual(hudLines(lines), [])
        XCTAssertEqual(desktop.fieldText, "HELLO")
    }

    func testJobsNeverEmitAPillLine() {
        let rule = Rule(
            trigger: "&&&",
            output: Guarded(primary: .shell(ShellOutput(script: "curl", background: true))))
        var lines: [String] = []
        let engine = Engine(
            config: KeypipeConfig(rules: [rule]), desktop: LineDesktop(app: "editor", line: nil),
            shell: { _, _, _, _ in .exited(0, stdout: "") }, emit: { lines.append($0) })
        engine.run(Job(rule: 0, input: "note", environment: ["KEYPIPE_APP": "editor"]))
        XCTAssertEqual(hudLines(lines), [])
    }

    func testNameIconAndHudParseWithDefaults() throws {
        let config = try loadConfig(
            data: Data(
                #"{"hud":false,"rules":[{"trigger":"@@@","name":"My Rule","icon":"🚀"}]}"#.utf8))
        XCTAssertFalse(config.hud)
        XCTAssertEqual(config.rules.first?.name, "My Rule")
        XCTAssertEqual(config.rules.first?.icon, "🚀")
        XCTAssertTrue(try loadConfig(data: Data(#"{"rules":[{"trigger":"@@@"}]}"#.utf8)).hud)
        let plain = try loadConfig(data: Data(#"{"rules":[{"trigger":"@@@"}]}"#.utf8))
        XCTAssertNil(plain.rules.first?.name)
        XCTAssertNil(plain.rules.first?.icon)
    }

    func testUnknownKeysAndShapesStillRejected() {
        for (json, reason) in [
            (#"{"rules":[{"trigger":"@@@","bogus":1}]}"#, "unknown key bogus"),
            (#"{"frobnicate":true,"rules":[]}"#, "unknown key frobnicate"),
            (#"{"hud":"yes","rules":[]}"#, "hud must be a boolean"),
            (#"{"rules":[{"trigger":"@@@","name":""}]}"#, "empty name"),
            (#"{"rules":[{"trigger":"@@@","icon":""}]}"#, "empty icon"),
        ] {
            XCTAssertThrowsError(try loadConfig(data: Data(json.utf8))) {
                XCTAssertEqual(
                    String(describing: $0), "keypipe: invalid config: \(reason)", json)
            }
        }
    }
}
