import XCTest

@testable import keypipe

/// Bounded-exhaustive check of the @@@ firing contract against the real
/// TriggerMatcher. See .claude/skills/verify-keypipe-trigger/SKILL.md.
final class TriggerExhaustiveTests: XCTestCase {
    private let alphabet: [Character] = ["@", "a", "\n", "\u{0301}"]
    private let maxLength = 8
    private let rule = TriggerRule(trigger: "@@@", action: Action(type: "log", message: "hit"))

    private func forEachInput(_ body: ([Character]) -> Bool) {
        var stack: [[Character]] = [[]]
        while let input = stack.popLast() {
            guard body(input) else { return }
            if input.count < maxLength {
                for ch in alphabet { stack.append(input + [ch]) }
            }
        }
    }

    /// Mirrors feedAndRun in Sources/keypipe/main.swift: feed each character,
    /// and on a hit run the action and reset the matcher.
    private func actualFires(_ input: [Character], maxBuffer: Int, resetOnHit: Bool) -> [Int] {
        var matcher = TriggerMatcher(rules: [rule], maxBuffer: maxBuffer)
        var fires: [Int] = []
        for (i, ch) in input.enumerated() where matcher.feed(ch) != nil {
            fires.append(i)
            if resetOnHit { matcher.reset() }
        }
        return fires
    }

    /// Spec: the action fires on the keystroke that completes three @ in a
    /// row since the last fire. Any other keystroke breaks the run.
    private func expectedFiresWithReset(_ input: [Character]) -> [Int] {
        var run = 0
        var fires: [Int] = []
        for (i, ch) in input.enumerated() {
            run = ch == "@" ? run + 1 : 0
            if run == 3 {
                fires.append(i)
                run = 0
            }
        }
        return fires
    }

    /// Spec without reset: feed reports a hit exactly when the last three
    /// keystrokes are @.
    private func expectedFiresWithoutReset(_ input: [Character]) -> [Int] {
        input.indices.filter { $0 >= 2 && input[($0 - 2)...$0].allSatisfy { $0 == "@" } }
    }

    private func describe(_ input: [Character]) -> String {
        input.map { $0 == "\n" ? "\\n" : $0 == "\u{0301}" ? "U+0301" : String($0) }
            .joined(separator: " ")
    }

    func testEveryInputFiresOncePerAtAtAtWithReset() {
        for maxBuffer in [3, 4, triggerMaxBuffer] {
            forEachInput { input in
                let actual = actualFires(input, maxBuffer: maxBuffer, resetOnHit: true)
                let expected = expectedFiresWithReset(input)
                if actual != expected {
                    XCTFail("maxBuffer \(maxBuffer), keys [\(describe(input))]: fired at \(actual), want \(expected)")
                    return false
                }
                return true
            }
        }
    }

    func testEveryInputHitsExactlyOnTrailingAtAtAt() {
        for maxBuffer in [3, 4, triggerMaxBuffer] {
            forEachInput { input in
                let actual = actualFires(input, maxBuffer: maxBuffer, resetOnHit: false)
                let expected = expectedFiresWithoutReset(input)
                if actual != expected {
                    XCTFail("maxBuffer \(maxBuffer), keys [\(describe(input))]: hit at \(actual), want \(expected)")
                    return false
                }
                return true
            }
        }
    }

    func testAtAtAtFiresAfterAnyPrefixUpToThreeBuffers() {
        for length in 0...(3 * triggerMaxBuffer) {
            let prefix = (0..<length).map { alphabet[$0 % alphabet.count] }
            let input = prefix + ["a", "@", "@", "@"]
            let actual = actualFires(input, maxBuffer: triggerMaxBuffer, resetOnHit: true)
            let expected = expectedFiresWithReset(input)
            XCTAssertEqual(actual, expected, "prefix length \(length)")
            XCTAssertEqual(actual.last, input.count - 1, "prefix length \(length): final @@@ must fire")
        }
    }
}
