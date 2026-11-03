import XCTest

@testable import keypipe

/// Ties Engine.fire to the HudFlow TLA+ model (.claude/skills/verify-keypipe-hud-flow):
/// for each way a fire ends, the engine posts exactly the window calls the model's
/// PostSpinner, PostHide and PostPill actions post, in that order.
final class HudFlowConformanceTests: XCTestCase {
    private func windows(
        _ rule: Rule, hud: Bool = true, desktop: FakeDesktop,
        shell: @escaping (String, String, [String: String], TimeInterval) -> ShellOutcome = {
            _, input, _, _ in .exited(0, stdout: input)
        },
        background: @escaping (Job) -> Bool = { _ in true }
    ) -> [String] {
        var engine = Engine(
            config: KeypipeConfig(rules: [rule], hud: hud), desktop: desktop, shell: shell,
            emit: { _ in }, background: background)
        for character in "@@@" {
            desktop.key(character)
            engine.key(character)
        }
        return desktop.windows
    }

    private let sync = Rule(trigger: "@@@", output: Guarded(primary: .shell("true")))

    func testOkPostsSpinHideThenPill() {
        XCTAssertEqual(
            windows(sync, desktop: FakeDesktop(focus: .text, fieldText: "x")),
            ["spin", "unspin", "pill"])
    }

    func testFailedPostsSpinHideThenPill() {
        XCTAssertEqual(
            windows(
                sync, desktop: FakeDesktop(focus: .text, fieldText: "x"),
                shell: { _, _, _, _ in .exited(1, stdout: "") }),
            ["spin", "unspin", "pill"])
    }

    func testStartedAndFailedSpawnPostSpinHideThenPill() {
        let bg = Rule(
            trigger: "@@@",
            output: Guarded(primary: .shell(ShellOutput(script: "cat", background: true))))
        XCTAssertEqual(
            windows(bg, desktop: FakeDesktop(focus: .text, fieldText: "x")),
            ["spin", "unspin", "pill"])
        XCTAssertEqual(
            windows(
                bg, desktop: FakeDesktop(focus: .text, fieldText: "x"), background: { _ in false }
            ),
            ["spin", "unspin", "pill"])
    }

    func testNoInputPostsSpinAndHideOnly() {
        let replace = Rule(
            trigger: "@@@", when: When(focus: .textField),
            output: Guarded(primary: .builtin(.replaceInput)))
        XCTAssertEqual(
            windows(
                replace,
                desktop: FakeDesktop(
                    focus: .text, fieldText: "hello", ignoresBackspace: true,
                    goneAfterErase: true)),
            ["spin", "unspin"])
    }

    func testGatedFirePostsNothing() {
        XCTAssertEqual(
            windows(sync, desktop: FakeDesktop(focus: .text, fieldText: "x", secure: true)), [])
    }

    func testHudOffPostsSpinAndHideOnly() {
        XCTAssertEqual(
            windows(sync, hud: false, desktop: FakeDesktop(focus: .text, fieldText: "x")),
            ["spin", "unspin"])
    }
}
