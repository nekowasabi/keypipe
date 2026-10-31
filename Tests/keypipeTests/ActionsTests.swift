import XCTest

@testable import keypipe

final class ActionsTests: XCTestCase {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
    }

    func testShellActionSideEffect() throws {
        let path = tempPath()
        let status = runAction(
            Action(type: "shell", command: "echo kp-shell-marker > \(path)"), logPath: nil)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(
            try String(contentsOfFile: path).trimmingCharacters(in: .whitespacesAndNewlines),
            "kp-shell-marker")
    }

    func testShellActionExitStatus() {
        XCTAssertEqual(runAction(Action(type: "shell", command: "exit 3"), logPath: nil), 3)
    }

    func testLogActionAppendsFile() throws {
        let path = tempPath()
        XCTAssertEqual(runAction(Action(type: "log", message: "kp-log-one"), logPath: path), 0)
        XCTAssertEqual(runAction(Action(type: "log", message: "kp-log-two"), logPath: path), 0)
        let lines = try String(contentsOfFile: path).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["kp-log-one", "kp-log-two"])
    }

    func testUnknownActionFails() {
        XCTAssertEqual(runAction(Action(type: "teleport"), logPath: nil), 1)
    }
}
