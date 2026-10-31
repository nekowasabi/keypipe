import XCTest

@testable import keypipe

final class TriggerTests: XCTestCase {
    func testDetectsCompletionAndResets() {
        var matcher = TriggerMatcher(triggers: ["@@@"])
        XCTAssertNil(matcher.feed("@"))
        XCTAssertNil(matcher.feed("@"))
        XCTAssertEqual(matcher.feed("@"), "@@@")
        matcher.reset()
        XCTAssertEqual(matcher.buffer, "")
        XCTAssertNil(matcher.feed("@"))
        XCTAssertNil(matcher.feed("@"))
        XCTAssertEqual(matcher.feed("@"), "@@@")
    }

    func testNoMatchOnOtherInput() {
        var matcher = TriggerMatcher(triggers: ["@@@"])
        for ch in "hello @@" { XCTAssertNil(matcher.feed(ch)) }
    }

    func testBufferSlidesToKeepSuffix() {
        var matcher = TriggerMatcher(triggers: ["@@@"], maxBuffer: 4)
        var hit: String?
        for ch in "abcdef@@@" { hit = matcher.feed(ch) }
        XCTAssertEqual(matcher.buffer, "f@@@")
        XCTAssertEqual(hit, "@@@")
    }

    func testDuplicateTriggersReturnTheString() {
        var matcher = TriggerMatcher(triggers: ["@@@", "@@@"])
        for ch in "@@" { XCTAssertNil(matcher.feed(ch)) }
        XCTAssertEqual(matcher.feed("@"), "@@@")
    }

    func testLongestMatchWinsInEitherOrder() {
        for triggers in [["ab", "aab"], ["aab", "ab"]] {
            var matcher = TriggerMatcher(triggers: triggers)
            var hit: String?
            for ch in "aab" { hit = matcher.feed(ch) }
            XCTAssertEqual(hit, "aab")
        }
    }
}
