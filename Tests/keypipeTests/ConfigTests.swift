import XCTest

@testable import keypipe

final class ConfigTests: XCTestCase {
    private func load(_ text: String) throws -> KeypipeConfig {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try loadConfig(path: url.path)
    }

    func testLoadsExampleAndDefaults() throws {
        let example = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "config.example.json")
        XCTAssertEqual(try loadConfig(path: example.path).rules.first?.trigger, "@@@")
        XCTAssertEqual(try load(#"{"rules":[{"trigger":"@@@"}]}"#).rules, [Rule(trigger: "@@@")])
        XCTAssertEqual(try load(#"{"rules":[]}"#).shellTimeout, 30)
        let guarded = try load(
            #"{"shellTimeout":2.5,"rules":[{"trigger":"@@@","when":{"focus":"textField"},"transform":"a","output":"replaceInput","onFail":{"transform":"b","output":{"shell":"c"}}}]}"#
        )
        XCTAssertEqual(guarded.shellTimeout, 2.5)
        XCTAssertEqual(guarded.rules.first?.transform, Guarded(primary: "a", onFail: "b"))
        XCTAssertEqual(
            guarded.rules.first?.output,
            Guarded(primary: .builtin(.replaceInput), onFail: .shell("c")))
        for (spec, canonical) in [
            ("ctrl+@", "ctrl+@"), ("command+option+x", "alt+cmd+x"), ("ctrl++", "ctrl++"),
        ] {
            let rule = try load(#"{"rules":[{"hotkey":"\#(spec)"}]}"#).rules.first
            XCTAssertEqual(rule?.trigger.description, canonical)
        }
    }

    func testRejectionReasons() {
        let cases = [
            (#"{"rules":[{"trigger":""}]}"#, "empty trigger"),
            (#"{"rules":[{"trigger":"@@@","action":{}}]}"#, "unknown key action"),
            (#"{"rules":[{"trigger":"@@@","output":"replaceAll"}]}"#, "unknown output replaceAll"),
            (#"{"rules":[{"trigger":"@@@","output":{"shell":""}}]}"#, "empty output.shell"),
            (#"{"rules":[{"trigger":"@@@","transform":""}]}"#, "empty transform"),
            (#"{"rules":[{"trigger":"@@@","when":{"focus":"window"}}]}"#, "unknown focus window"),
            (
                #"{"rules":[{"trigger":"@@@","output":"replaceInput"}]}"#,
                "output replaceInput requires focus textField"
            ),
            (#"{"rules":[{"output":"none"}]}"#, "rule needs trigger or hotkey"),
            (
                #"{"rules":[{"trigger":"@@@","onFail":{"transform":"x"}}]}"#,
                "onFail.transform requires transform"
            ),
            (
                #"{"rules":[{"trigger":"@@@","output":"notify","onFail":{"output":"none"}}]}"#,
                "onFail.output requires an output that can fail"
            ),
            (
                #"{"rules":[{"trigger":"@@@","output":{"shell":"x"},"onFail":{"output":"replaceInput"}}]}"#,
                "output replaceInput requires focus textField"
            ),
            (#"{"rules":[{"trigger":"@@@","onFail":{"erase":"x"}}]}"#, "unknown key erase"),
            (
                #"{"rules":[{"trigger":"@@@","transform":"x","onFail":{"transform":""}}]}"#,
                "empty transform"
            ),
            (
                #"{"rules":[{"trigger":"@@@","output":{"shell":"x"},"onFail":{"output":{"shell":""}}}]}"#,
                "empty output.shell"
            ),
            (#"{"shellTimeout":0,"rules":[]}"#, "shellTimeout must be positive"),
            (#"{"shellTimeout":"5","rules":[]}"#, "shellTimeout must be positive"),
            (
                #"{"rules":[{"trigger":"@@@","hotkey":"ctrl+@"}]}"#,
                "rule has both trigger and hotkey"
            ),
            (#"{"rules":[{"hotkey":"@"}]}"#, "hotkey needs a modifier"),
            (#"{"rules":[{"hotkey":"meta+@"}]}"#, "unknown modifier meta"),
            (#"{"rules":[{"hotkey":"ctrl+shift+a"}]}"#, "shift is written in the key (ctrl+A)"),
            (#"{"rules":[{"hotkey":"ctrl+"}]}"#, "empty hotkey key"),
            (#"{"rules":[{"hotkey":"ctrl+ab"}]}"#, "hotkey key must be one character"),
            (#"{"rules":[{"trigger":"@@@","when":{"apps":[]}}]}"#, "unknown key apps"),
            (
                #"{"rules":[{"trigger":"@@@","output":{"shell":"true","extra":true}}]}"#,
                "unknown key extra"
            ),
            (#"{"backgroundTimeout":0,"rules":[]}"#, "backgroundTimeout must be positive"),
            (#"{"backgroundTimeout":-1,"rules":[]}"#, "backgroundTimeout must be positive"),
            (
                #"{"rules":[{"trigger":"@@@","output":{"shell":"x","background":"yes"}}]}"#,
                "background must be a boolean"
            ),
            (
                #"{"rules":[{"trigger":"@@@","output":{"shell":"x"},"onFail":{"output":{"shell":"y","background":true}}}]}"#,
                "unknown key background"
            ),
            (
                #"{"rules":[{"trigger":"@@@","when":{"focus":"textField"},"output":{"shell":"x","background":true},"onFail":{"output":"replaceInput"}}]}"#,
                "a background output cannot fall back to replaceInput"
            ),
        ]
        for (json, reason) in cases {
            XCTAssertThrowsError(try load(json)) {
                XCTAssertEqual(String(describing: $0), "keypipe: invalid config: \(reason)")
            }
        }
    }

    func testBackgroundShellAndItsTimeout() throws {
        XCTAssertEqual(try load(#"{"rules":[]}"#).backgroundTimeout, 300)
        let config = try load(
            #"{"backgroundTimeout":2,"rules":[{"trigger":"&&&","output":{"shell":"curl","background":true}},{"trigger":";;;","output":{"shell":"curl"}}]}"#
        )
        XCTAssertEqual(config.backgroundTimeout, 2)
        XCTAssertEqual(
            config.rules[0].output.primary, .shell(ShellOutput(script: "curl", background: true)))
        XCTAssertEqual(config.rules[1].output.primary, .shell("curl"))
        XCTAssertFalse(config.rules[1].output.primary.isBackground)
    }

    func testTextFieldAllowsReplacement() throws {
        let config = try load(
            #"{"rules":[{"trigger":"@@@","when":{"focus":"textField"},"output":"replaceInput"}]}"#)
        XCTAssertEqual(config.rules[0].output.primary, .builtin(.replaceInput))
    }

    func testTriggerLengthBoundary() throws {
        let max = String(repeating: "a", count: triggerMaxBuffer)
        XCTAssertEqual(try load(#"{"rules":[{"trigger":"\#(max)"}]}"#).rules.count, 1)
        XCTAssertThrowsError(try load(#"{"rules":[{"trigger":"\#(max)a"}]}"#))
    }

    func testMalformedShapesAndMissingFile() {
        for json in [
            "{bad", "[]", #"{"rules":{}}"#, #"{"rules":[{"trigger":3}]}"#,
            #"{"rules":[{"trigger":"x","when":{"app":"app"}}]}"#,
            #"{"rules":[{"trigger":"x","transform":false}]}"#,
        ] {
            XCTAssertThrowsError(try load(json))
        }
        XCTAssertThrowsError(try loadConfig(path: "/nonexistent/keypipe.json"))
    }
}
