import XCTest

@testable import keypipe

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
    }

    func testFirstSatisfiedRuleWins() {
        let first = Rule(trigger: "@@@", output: Guarded(primary: .builtin(.notify)))
        let second = Rule(trigger: "@@@")
        XCTAssertEqual(select([first, second], Snapshot(focus: .text)), first)
    }
}
