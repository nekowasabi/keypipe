import XCTest

@testable import keypipe

final class TriggerTests: XCTestCase {
    private func atAtAtRule() -> TriggerRule {
        TriggerRule(
            trigger: "@@@",
            action: Action(type: "shell", command: "echo keypipe-triggered")
        )
    }

    func testDetectsAtAtAtCompletion() {
        var matcher = TriggerMatcher(rules: [atAtAtRule()])
        XCTAssertNil(matcher.feed("@"))
        XCTAssertNil(matcher.feed("@"))
        let hit = matcher.feed("@")
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.trigger, "@@@")
        XCTAssertEqual(hit?.action.command, "echo keypipe-triggered")
    }

    func testNoMatchOnOtherInput() {
        var matcher = TriggerMatcher(rules: [atAtAtRule()])
        for ch in "hello @@" {
            XCTAssertNil(matcher.feed(ch))
        }
    }

    func testMatchNeedsSuffix() {
        var matcher = TriggerMatcher(rules: [atAtAtRule()])
        for ch in "@@x@@@" {
            _ = matcher.feed(ch)
        }
        XCTAssertTrue(matcher.buffer.hasSuffix("@@@"))
    }

    func testResetClearsBuffer() {
        var matcher = TriggerMatcher(rules: [atAtAtRule()])
        _ = matcher.feed("@")
        matcher.reset()
        XCTAssertEqual(matcher.buffer, "")
        XCTAssertNil(matcher.feed("@"))
    }

    func testBufferTrimsToMaxBuffer() {
        var matcher = TriggerMatcher(rules: [atAtAtRule()], maxBuffer: 4)
        for ch in "abcdef@@@" {
            _ = matcher.feed(ch)
        }
        XCTAssertEqual(matcher.buffer.count, 4)
        XCTAssertTrue(matcher.buffer.hasSuffix("@@@"))
    }

    func testFirstRuleWins() {
        var matcher = TriggerMatcher(rules: [
            TriggerRule(trigger: "@@@", action: Action(type: "log", message: "first")),
            TriggerRule(trigger: "@@@", action: Action(type: "log", message: "second")),
        ])
        _ = matcher.feed("@")
        _ = matcher.feed("@")
        XCTAssertEqual(matcher.feed("@")?.action.message, "first")
    }

    func testLongestMatchWins() {
        let rules = [
            TriggerRule(trigger: "ab", action: Action(type: "log", message: "short")),
            TriggerRule(trigger: "aab", action: Action(type: "log", message: "long")),
        ]
        var forward = TriggerMatcher(rules: rules)
        var hit: TriggerRule?
        for ch in "aab" { hit = forward.feed(ch) }
        XCTAssertEqual(hit?.trigger, "aab")
        var reversed = TriggerMatcher(rules: rules.reversed())
        hit = nil
        for ch in "aab" { hit = reversed.feed(ch) }
        XCTAssertEqual(hit?.trigger, "aab")
    }

    func testRefiresAfterReset() {
        var matcher = TriggerMatcher(rules: [atAtAtRule()])
        for ch in "@@@" { _ = matcher.feed(ch) }
        matcher.reset()
        var hit: TriggerRule?
        for ch in "@@@" { hit = matcher.feed(ch) }
        XCTAssertEqual(hit?.trigger, "@@@")
    }

    func testBufferSlidesToKeepSuffix() {
        var matcher = TriggerMatcher(rules: [atAtAtRule()], maxBuffer: 4)
        var hit: TriggerRule?
        for ch in "xyz@@@" { hit = matcher.feed(ch) }
        XCTAssertEqual(hit?.trigger, "@@@")
    }
}
