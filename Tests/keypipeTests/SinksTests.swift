import XCTest

@testable import keypipe

final class SinksTests: XCTestCase {
    private func load(_ json: String) throws -> KeypipeConfig { try loadConfig(data: Data(json.utf8)) }

    /// P9: every output rule comes from the sink's spec, for every sink, with today's messages.
    func testValidityIsDerivedFromEverySinkSpec() throws {
        for sink in BuiltinSink.allCases {
            let name = sink.rawValue
            let anyFocus = #"{"rules":[{"trigger":"@@@","output":"\#(name)"}]}"#
            if sink.spec.needsTextField {
                XCTAssertThrowsError(try load(anyFocus)) {
                    XCTAssertEqual(String(describing: $0), "keypipe: invalid config: output \(name) requires focus textField")
                }
            } else {
                XCTAssertNoThrow(try load(anyFocus), name)
            }
            let withFallback = #"{"rules":[{"trigger":"@@@","when":{"focus":"textField"},"output":"\#(name)","onFail":{"output":"notify"}}]}"#
            if sink.spec.canFail {
                XCTAssertNoThrow(try load(withFallback), name)
            } else {
                XCTAssertThrowsError(try load(withFallback)) {
                    XCTAssertEqual(String(describing: $0), "keypipe: invalid config: onFail.output requires an output that can fail")
                }
            }
            let asBackgroundFallback = #"{"rules":[{"trigger":"@@@","when":{"focus":"textField"},"output":{"shell":"x","background":true},"onFail":{"output":"\#(name)"}}]}"#
            if sink.spec.detachable {
                XCTAssertNoThrow(try load(asBackgroundFallback), name)
            } else {
                XCTAssertThrowsError(try load(asBackgroundFallback)) {
                    XCTAssertEqual(String(describing: $0), "keypipe: invalid config: a background output cannot fall back to \(name)")
                }
            }
        }
    }

    func testTypeTextTypesAtTheCaretAndIsDelivered() {
        let desktop = FakeDesktop(focus: .text, fieldText: "date: ")
        let rule = Rule(trigger: "@@@", transform: Guarded(primary: "date"), output: Guarded(primary: .builtin(.typeText)))
        var lines: [String] = []
        var engine = Engine(config: KeypipeConfig(rules: [rule]), desktop: desktop,
                            shell: { _, _, _, _ in .exited(0, stdout: "2026-11-01") }, emit: { lines.append($0) })
        for c in "@@@" { desktop.key(c) }
        XCTAssertEqual(engine.fire("@@@"), .delivered(rule: 0, viaFallback: false))
        XCTAssertEqual(desktop.fieldText, "date: 2026-11-01")
        XCTAssertTrue(lines.contains(#"keypipe apply typeText "2026-11-01""#))
    }

    /// P10: no fake success. A desktop that cannot type reports unsupported, the text is
    /// notified so it is not lost, and onFail.output can take it instead.
    func testTypeTextWithoutACaretFailsAsUnsupported() {
        let plain = Rule(trigger: "@@@", when: When(focus: .textField), output: Guarded(primary: .builtin(.typeText)))
        let line = LineDesktop(app: "editor", line: "hello@@@")
        var engine = Engine(config: KeypipeConfig(rules: [plain]), desktop: line,
                            shell: { _, input, _, _ in .exited(0, stdout: input) }, emit: { _ in })
        XCTAssertEqual(engine.fire("@@@"), .failed(rule: 0, stage: .output, failure: "unsupported"))
        XCTAssertEqual(line.line, "hello", "the line is not changed")

        let fallback = Rule(trigger: "@@@", when: When(focus: .textField),
                            output: Guarded(primary: .builtin(.typeText), onFail: .shell("save")))
        var saved: [String: String] = [:]
        var engine2 = Engine(config: KeypipeConfig(rules: [fallback]), desktop: LineDesktop(app: "editor", line: "hi@@@"),
                             shell: { script, input, env, _ in
                                 saved[script] = "\(input)|\(env["KEYPIPE_FAILURE"] ?? "")"
                                 return .exited(0, stdout: "")
                             }, emit: { _ in })
        XCTAssertEqual(engine2.fire("@@@"), .delivered(rule: 0, viaFallback: true))
        XCTAssertEqual(saved["save"], "hi|unsupported")
    }
}
