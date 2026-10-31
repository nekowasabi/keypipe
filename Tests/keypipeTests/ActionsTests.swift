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
            Action(type: "shell", command: "echo kp-shell-marker > \(path)"))
        XCTAssertEqual(status, 0)
        XCTAssertEqual(
            try String(contentsOfFile: path).trimmingCharacters(in: .whitespacesAndNewlines),
            "kp-shell-marker")
    }

    func testShellActionExitStatus() {
        XCTAssertEqual(runAction(Action(type: "shell", command: "exit 3")), 3)
    }

    func testUnknownActionFails() {
        XCTAssertEqual(runAction(Action(type: "teleport")), 1)
    }
}
