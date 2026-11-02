import XCTest

@testable import keypipe

/// The first rule whose `when` holds on a snapshot alone (a fact beyond it counts as absent).
private func select(_ candidates: [Rule], _ snapshot: Snapshot) -> Rule? {
    candidates.first { evaluate($0.when, FactSheet(snapshot, desktop: nil)) == .match }
}

final class ContextTests: XCTestCase {
    func testFocusAndAppSelection() {
        let any = Rule(trigger: "@@@")
        let app = Rule(trigger: "@@@", when: When(app: ["terminal"]))
        let text = Rule(trigger: "@@@", when: When(focus: .textField))
        XCTAssertEqual(select([app, text, any], Snapshot(app: "editor", focus: .text)), text)
        XCTAssertEqual(select([app, text, any], Snapshot(app: "terminal", focus: .nothing)), app)
        XCTAssertEqual(select([app, text, any], Snapshot(focus: .nothing)), any)
        XCTAssertNil(select([app, text], Snapshot(focus: .nothing)))
        XCTAssertNil(select([any], Snapshot(focus: .composing)))
        XCTAssertNil(
            select([app, text, any], Snapshot(app: "terminal", focus: .terminal)),
            "a terminal pane is never a field")
    }

    func testFirstSatisfiedRuleWins() {
        let first = Rule(trigger: "@@@", output: Guarded(primary: .builtin(.notify)))
        let second = Rule(trigger: "@@@")
        XCTAssertEqual(select([first, second], Snapshot(focus: .text)), first)
    }
}

final class FakeDesktopContextTests: XCTestCase {
    func testOwnsPtyIsTerminalFocusWithoutAField() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try
            #"{"app":"com.example.someterm","ownsPty":true,"focusIsTextField":true,"fieldText":"pane"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            try FakeDesktop(path: url.path).snapshot(),
            Snapshot(app: "com.example.someterm", focus: .terminal))
    }
}
