import XCTest

@testable import keypipe

final class ConfigTests: XCTestCase {
    private func writeTemp(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testLoadsExampleConfig() throws {
        let example = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("config.example.json").path
        let config = try loadConfig(path: example)
        XCTAssertTrue(config.rules.contains { $0.trigger == "@@@" })
    }

    func testLoadsMinimalRule() throws {
        let path = try writeTemp(
            #"{"rules": [{"trigger": "@@@", "action": {"type": "shell", "command": "echo hi"}}]}"#)
        let config = try loadConfig(path: path)
        XCTAssertEqual(config.rules.count, 1)
    }

    func testBadJSONThrows() throws {
        let path = try writeTemp("{bad json")
        XCTAssertThrowsError(try loadConfig(path: path))
    }

    func testUnknownActionTypeThrows() throws {
        let path = try writeTemp(
            #"{"rules": [{"trigger": "@@@", "action": {"type": "teleport"}}]}"#)
        XCTAssertThrowsError(try loadConfig(path: path))
    }

    func testEmptyTriggerThrows() throws {
        let path = try writeTemp(
            #"{"rules": [{"trigger": "", "action": {"type": "shell", "command": "true"}}]}"#)
        XCTAssertThrowsError(try loadConfig(path: path))
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try loadConfig(path: "/nonexistent/keypipe.json"))
    }

    func testLongTriggerThrows() {
        let long = String(repeating: "a", count: triggerMaxBuffer + 1)
        let path = try! writeTemp(
            #"{"rules": [{"trigger": "\#(long)", "action": {"type": "shell", "command": "true"}}]}"#)
        XCTAssertThrowsError(try loadConfig(path: path))
    }

    func testMaxLengthTriggerAccepted() throws {
        let max = String(repeating: "a", count: triggerMaxBuffer)
        let path = try writeTemp(
            #"{"rules": [{"trigger": "\#(max)", "action": {"type": "shell", "command": "true"}}]}"#)
        let config = try loadConfig(path: path)
        XCTAssertEqual(config.rules.count, 1)
    }
}
