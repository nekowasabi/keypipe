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
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config.example.json")
        XCTAssertEqual(try loadConfig(path: example.path).rules.first?.trigger, "@@@")
        XCTAssertEqual(try load(#"{"rules":[{"trigger":"@@@"}]}"#).rules, [Rule(trigger: "@@@")])
        for (spec, canonical) in [("ctrl+@", "ctrl+@"), ("command+option+x", "alt+cmd+x"), ("ctrl++", "ctrl++")] {
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
            (#"{"rules":[{"trigger":"@@@","output":"replaceInput"}]}"#, "output replaceInput requires focus textField"),
            (#"{"rules":[],"shellTimeout":1}"#, "unknown key shellTimeout"),
            (#"{"rules":[{"trigger":"@@@","onFail":{}}]}"#, "unknown key onFail"),
            (#"{"rules":[{"output":"none"}]}"#, "rule needs trigger or hotkey"),
            (#"{"rules":[{"trigger":"@@@","hotkey":"ctrl+@"}]}"#, "rule has both trigger and hotkey"),
            (#"{"rules":[{"hotkey":"@"}]}"#, "hotkey needs a modifier"),
            (#"{"rules":[{"hotkey":"meta+@"}]}"#, "unknown modifier meta"),
            (#"{"rules":[{"hotkey":"ctrl+shift+a"}]}"#, "shift is written in the key (ctrl+A)"),
            (#"{"rules":[{"hotkey":"ctrl+"}]}"#, "empty hotkey key"),
            (#"{"rules":[{"hotkey":"ctrl+ab"}]}"#, "hotkey key must be one character"),
            (#"{"rules":[{"trigger":"@@@","when":{"apps":[]}}]}"#, "unknown key apps"),
            (#"{"rules":[{"trigger":"@@@","output":{"shell":"true","extra":true}}]}"#, "unknown key extra"),
        ]
        for (json, reason) in cases {
            XCTAssertThrowsError(try load(json)) {
                XCTAssertEqual(String(describing: $0), "keypipe: invalid config: \(reason)")
            }
        }
    }

    func testTextFieldAllowsReplacement() throws {
        let config = try load(#"{"rules":[{"trigger":"@@@","when":{"focus":"textField"},"output":"replaceInput"}]}"#)
        XCTAssertEqual(config.rules[0].output.primary, .builtin(.replaceInput))
    }

    func testTriggerLengthBoundary() throws {
        let max = String(repeating: "a", count: triggerMaxBuffer)
        XCTAssertEqual(try load(#"{"rules":[{"trigger":"\#(max)"}]}"#).rules.count, 1)
        XCTAssertThrowsError(try load(#"{"rules":[{"trigger":"\#(max)a"}]}"#))
    }

    func testMalformedShapesAndMissingFile() {
        for json in ["{bad", "[]", #"{"rules":{}}"#, #"{"rules":[{"trigger":3}]}"#,
                     #"{"rules":[{"trigger":"x","when":{"app":"app"}}]}"#,
                     #"{"rules":[{"trigger":"x","transform":false}]}"#] {
            XCTAssertThrowsError(try load(json))
        }
        XCTAssertThrowsError(try loadConfig(path: "/nonexistent/keypipe.json"))
    }
}
