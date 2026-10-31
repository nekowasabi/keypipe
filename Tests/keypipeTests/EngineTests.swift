import XCTest

@testable import keypipe

final class EngineTests: XCTestCase {
    private func run(_ keys: String = "@@@", rules: [Rule], desktop: FakeDesktop,
                     shell: @escaping (String, String, [String: String], TimeInterval) -> ShellOutcome = { _, input, _, _ in .exited(0, stdout: input) }) -> (Int, [String]) {
        var lines: [String] = []
        var engine = Engine(config: KeypipeConfig(rules: rules), desktop: desktop, shell: shell) { lines.append($0) }
        for character in keys {
            desktop.key(character)
            engine.key(character)
        }
        return (engine.hits, lines)
    }

    func testComposingDoesNotFireOrErase() {
        let desktop = FakeDesktop(focus: .composing, fieldText: "hello")
        let (hits, lines) = run(rules: [Rule(trigger: "@@@")], desktop: desktop, shell: { _, _, _, _ in
            XCTFail("shell called during composition")
            return .exited(0, stdout: "")
        })
        XCTAssertEqual(hits, 0)
        XCTAssertEqual(lines, ["keypipe composing @@@"])
        XCTAssertEqual(desktop.fieldText, "hello@@@")
    }

    func testBackspaceAndRewriteRemoveOnlyOneTrigger() {
        for ignores in [false, true] {
            let desktop = FakeDesktop(focus: .text, fieldText: "@@@", ignoresBackspace: ignores)
            let rule = Rule(trigger: "@@@", when: When(focus: .textField))
            let (hits, lines) = run(rules: [rule], desktop: desktop)
            XCTAssertEqual(hits, 1)
            XCTAssertEqual(desktop.fieldText, "@@@")
            XCTAssertEqual(lines.contains("keypipe erase-rewrite"), ignores)
        }
    }

    func testEraseWaitsForEveryBackspaceBeforeReading() {
        let desktop = FakeDesktop(focus: .text, fieldText: "hello", backspacePerRead: true)
        let rule = Rule(trigger: "@@@", when: When(focus: .textField),
                        transform: Guarded(primary: "tr"), output: Guarded(primary: .builtin(.replaceInput)))
        let (_, lines) = run(rules: [rule], desktop: desktop) { _, input, _, _ in
            XCTAssertEqual(input, "hello")
            return .exited(0, stdout: "HELLO")
        }
        XCTAssertFalse(lines.contains("keypipe erase-rewrite"))
        XCTAssertEqual(desktop.fieldText, "HELLO")
    }

    func testEraseWaitsForTheTriggerToLandBeforeBackspacing() {
        let desktop = FakeDesktop(focus: .text, fieldText: "hello", keysPerRead: true)
        let rule = Rule(trigger: "@@@", when: When(focus: .textField),
                        transform: Guarded(primary: "tr"), output: Guarded(primary: .builtin(.replaceInput)))
        let (_, lines) = run(rules: [rule], desktop: desktop) { _, input, _, _ in
            XCTAssertEqual(input, "hello")
            return .exited(0, stdout: "HELLO")
        }
        XCTAssertFalse(lines.contains("keypipe erase-rewrite"))
        XCTAssertEqual(desktop.fieldText, "HELLO")
    }

    func testEmptyTransformOutputNotifiesInsteadOfWipingField() {
        let desktop = FakeDesktop(focus: .text, fieldText: "hello")
        let rule = Rule(trigger: "@@@", when: When(focus: .textField),
                        transform: Guarded(primary: "true"), output: Guarded(primary: .builtin(.replaceInput)))
        let (_, lines) = run(rules: [rule], desktop: desktop) { _, _, _, _ in .exited(0, stdout: "") }
        XCTAssertTrue(lines.contains("keypipe transform empty"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("keypipe apply replaceInput") })
        XCTAssertEqual(desktop.notifications, ["@@@ transform failed: empty"])
        XCTAssertEqual(desktop.fieldText, "hello")
    }

    func testAnySuppliesEmptyInputAndErasesOnlyInTextFields() {
        for focus in [Focus.text, .nothing] {
            let desktop = FakeDesktop(app: "editor", focus: focus, fieldText: "hello")
            let rule = Rule(trigger: "@@@", output: Guarded(primary: .shell("send")))
            var called = false
            let (_, lines) = run(rules: [rule], desktop: desktop) { script, input, env, timeout in
                called = true
                XCTAssertEqual(script, "send")
                XCTAssertEqual(input, "")
                XCTAssertEqual(env, ["KEYPIPE_APP": "editor"])
                XCTAssertEqual(timeout, 30)
                return .exited(0, stdout: "")
            }
            XCTAssertTrue(called)
            XCTAssertTrue(lines.contains("keypipe erase \(focus == .text ? 3 : 0)"))
            XCTAssertEqual(desktop.fieldText, focus == .text ? "hello" : "hello@@@")
        }
    }

    func testFailedTransformNotifiesAndPreservesErasedField() {
        let desktop = FakeDesktop(focus: .text, fieldText: "hello")
        let rule = Rule(trigger: "@@@", when: When(focus: .textField),
                        transform: Guarded(primary: "exit 3"), output: Guarded(primary: .builtin(.replaceInput)))
        let (hits, lines) = run(rules: [rule], desktop: desktop) { _, input, _, _ in
            XCTAssertEqual(input, "hello")
            return .exited(3, stdout: "ignored")
        }
        XCTAssertEqual(hits, 1)
        XCTAssertTrue(lines.contains("keypipe transform exit 3"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("keypipe apply replaceInput") })
        XCTAssertEqual(desktop.notifications, ["@@@ transform failed: exit 3"])
        XCTAssertEqual(desktop.fieldText, "hello")
    }

    func testNoMatchDoesNotEraseOrTryShorterTrigger() {
        let desktop = FakeDesktop(focus: .nothing)
        let rules = [Rule(trigger: "aab", when: When(focus: .textField)), Rule(trigger: "ab")]
        let (hits, lines) = run("aab", rules: rules, desktop: desktop)
        XCTAssertEqual(hits, 0)
        XCTAssertEqual(lines, ["keypipe nomatch aab"])
        XCTAssertEqual(desktop.fieldText, "aab")
    }

    func testTransformationFeedsReplacementAndKeepsUnicode() {
        let desktop = FakeDesktop(focus: .text, fieldText: "こんにちは")
        let rule = Rule(trigger: "@@@", when: When(focus: .textField),
                        transform: Guarded(primary: "transform"), output: Guarded(primary: .builtin(.replaceInput)))
        let (_, lines) = run(rules: [rule], desktop: desktop) { _, input, _, _ in
            XCTAssertEqual(input, "こんにちは")
            return .exited(0, stdout: "Hello\nworld")
        }
        XCTAssertEqual(desktop.fieldText, "Hello\nworld")
        XCTAssertTrue(lines.contains(#"keypipe apply replaceInput "Hello\nworld""#))
    }

    func testContextRejectsCompositionWithoutTextField() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try #"{"focusIsTextField":false,"fieldText":"","composing":true}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try FakeDesktop(path: url.path)) {
            XCTAssertEqual(String(describing: $0), "keypipe: invalid config: composing requires focusIsTextField")
        }
    }
}
