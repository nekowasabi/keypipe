import XCTest

@testable import keypipe

final class SinksTests: XCTestCase {
    private func load(_ json: String) throws -> KeypipeConfig {
        try loadConfig(data: Data(json.utf8))
    }

    /// P9: every output rule comes from the sink's spec, for every sink, with today's messages.
    func testValidityIsDerivedFromEverySinkSpec() throws {
        for sink in BuiltinSink.allCases {
            let name = sink.rawValue
            let anyFocus = #"{"rules":[{"trigger":"@@@","output":"\#(name)"}]}"#
            if sink.spec.needsTextField {
                XCTAssertThrowsError(try load(anyFocus)) {
                    XCTAssertEqual(
                        String(describing: $0),
                        "keypipe: invalid config: output \(name) requires focus textField")
                }
            } else {
                XCTAssertNoThrow(try load(anyFocus), name)
            }
            let withFallback =
                #"{"rules":[{"trigger":"@@@","when":{"focus":"textField"},"output":"\#(name)","onFail":{"output":"notify"}}]}"#
            if sink.spec.canFail {
                XCTAssertNoThrow(try load(withFallback), name)
            } else {
                XCTAssertThrowsError(try load(withFallback)) {
                    XCTAssertEqual(
                        String(describing: $0),
                        "keypipe: invalid config: onFail.output requires an output that can fail")
                }
            }
            let asBackgroundFallback =
                #"{"rules":[{"trigger":"@@@","when":{"focus":"textField"},"output":{"shell":"x","background":true},"onFail":{"output":"\#(name)"}}]}"#
            if sink.spec.detachable {
                XCTAssertNoThrow(try load(asBackgroundFallback), name)
            } else {
                XCTAssertThrowsError(try load(asBackgroundFallback)) {
                    XCTAssertEqual(
                        String(describing: $0),
                        "keypipe: invalid config: a background output cannot fall back to \(name)")
                }
            }
        }
    }

    func testTypeTextTypesAtTheCaretAndIsDelivered() {
        let desktop = FakeDesktop(focus: .text, fieldText: "date: ")
        let rule = Rule(
            trigger: "@@@", transform: Guarded(primary: "date"),
            output: Guarded(primary: .builtin(.typeText)))
        var lines: [String] = []
        var engine = Engine(
            config: KeypipeConfig(rules: [rule]), desktop: desktop,
            shell: { _, _, _, _ in .exited(0, stdout: "2026-11-01") }, emit: { lines.append($0) })
        for c in "@@@" { desktop.key(c) }
        XCTAssertEqual(engine.fire("@@@"), .delivered(rule: 0, viaFallback: false))
        XCTAssertEqual(desktop.fieldText, "date: 2026-11-01")
        XCTAssertTrue(lines.contains(#"keypipe apply typeText "2026-11-01""#))
    }

    /// P10: no fake success. A desktop that cannot type reports unsupported, the text is
    /// notified so it is not lost, and onFail.output can take it instead.
    func testTypeTextWithoutACaretFailsAsUnsupported() {
        let plain = Rule(
            trigger: "@@@", when: When(focus: .textField),
            output: Guarded(primary: .builtin(.typeText)))
        let line = LineDesktop(app: "editor", line: "hello@@@")
        var engine = Engine(
            config: KeypipeConfig(rules: [plain]), desktop: line,
            shell: { _, input, _, _ in .exited(0, stdout: input) }, emit: { _ in })
        XCTAssertEqual(engine.fire("@@@"), .failed(rule: 0, stage: .output, failure: "unsupported"))
        XCTAssertEqual(line.line, "hello", "the line is not changed")

        let fallback = Rule(
            trigger: "@@@", when: When(focus: .textField),
            output: Guarded(primary: .builtin(.typeText), onFail: .shell("save")))
        var saved: [String: String] = [:]
        var engine2 = Engine(
            config: KeypipeConfig(rules: [fallback]),
            desktop: LineDesktop(app: "editor", line: "hi@@@"),
            shell: { script, input, env, _ in
                saved[script] = "\(input)|\(env["KEYPIPE_FAILURE"] ?? "")"
                return .exited(0, stdout: "")
            }, emit: { _ in })
        XCTAssertEqual(engine2.fire("@@@"), .delivered(rule: 0, viaFallback: true))
        XCTAssertEqual(saved["save"], "hi|unsupported")
    }

    /// The keys go only where the rule fired: if the front moved during the transform (an app deny
    /// would have stopped, a terminal, a password field, another field), nothing is typed and the
    /// output fails as gone, for the primary output and for onFail.output alike.
    func testTypeTextTypesNothingWhenTheFrontMovedDuringTheTransform() {
        final class Moving: Desktop {
            var front: Snapshot
            var typed: [String] = []
            init(_ front: Snapshot) { self.front = front }
            func snapshot() -> Snapshot { front }
            func backspace(_ count: Int) {}
            func text(_ field: Field) -> String? { "x@@@" }
            func setText(_ field: Field, _ text: String) -> Bool { true }
            func notify(_ text: String) {}
            func typeText(_ text: String) -> Bool {
                typed.append(text)
                return true
            }
        }
        let origin = Snapshot(app: "allowed.app", focus: .text, field: Field(token: 0))
        let moves = [
            Snapshot(app: "denied.app", focus: .text, field: Field(token: 0)),
            Snapshot(app: "allowed.app", focus: .terminal),
            Snapshot(app: "allowed.app", focus: .nothing, secure: true),
            Snapshot(app: "allowed.app", focus: .text, field: Field(token: 1)),
        ]
        for onFail in [nil, Output.builtin(.typeText)] {
            for later in moves {
                let desktop = Moving(origin)
                let rule = Rule(
                    trigger: "@@@", when: When(app: ["allowed.app"], focus: .textField),
                    transform: Guarded(primary: "slow"),
                    output: Guarded(primary: .builtin(.typeText), onFail: onFail))
                var engine = Engine(
                    config: KeypipeConfig(
                        rules: [rule], deny: [Conditions([Term(fact: .app, globs: ["denied.app"])])]
                    ),
                    desktop: desktop,
                    shell: { _, _, _, _ in
                        desktop.front = later
                        return .exited(0, stdout: "SECRET")
                    }, emit: { _ in })
                XCTAssertEqual(
                    engine.fire("@@@"), .failed(rule: 0, stage: .output, failure: "gone"),
                    "\(later)")
                XCTAssertEqual(desktop.typed, [], "typed into \(later)")
            }
        }
        // Unmoved, it types.
        let desktop = Moving(origin)
        var engine = Engine(
            config: KeypipeConfig(rules: [
                Rule(
                    trigger: "@@@", when: When(focus: .textField),
                    output: Guarded(primary: .builtin(.typeText)))
            ]),
            desktop: desktop, shell: { _, input, _, _ in .exited(0, stdout: input) }, emit: { _ in }
        )
        XCTAssertEqual(engine.fire("@@@"), .delivered(rule: 0, viaFallback: false))
        XCTAssertEqual(desktop.typed.count, 1, "unmoved, the result is typed once")

        // A focus-any hotkey in a terminal (no field on either side) still types there.
        let terminal = Moving(Snapshot(app: "com.mitchellh.ghostty", focus: .terminal))
        let chord = try! Hotkey.parse("ctrl+@")
        var inTerminal = Engine(
            config: KeypipeConfig(rules: [
                Rule(trigger: .hotkey(chord), output: Guarded(primary: .builtin(.typeText)))
            ]),
            desktop: terminal, shell: { _, _, _, _ in .exited(0, stdout: "") }, emit: { _ in })
        XCTAssertEqual(inTerminal.fire(.hotkey(chord)), .delivered(rule: 0, viaFallback: false))
        XCTAssertEqual(terminal.typed, [""])
    }

    /// The fake keeps MacDesktop's contract: no caret with nothing focused or in a password field.
    func testTypeTextNeedsACaretOnEveryDesktop() {
        XCTAssertFalse(FakeDesktop(focus: .nothing).typeText("x"))
        XCTAssertFalse(FakeDesktop(focus: .text, secure: true).typeText("x"))
        XCTAssertTrue(FakeDesktop(focus: .terminal).typeText("x"))
        XCTAssertTrue(FakeDesktop(focus: .text).typeText("x"))
    }
}
