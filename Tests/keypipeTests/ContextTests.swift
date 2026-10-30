import XCTest
@testable import keypipe

final class ContextTests: XCTestCase {
    func testStubAlwaysMatchesNil() {
        XCTAssertTrue(contextMatches(nil, app: nil))
    }

    func testStubAlwaysMatchesWithValues() {
        let rule = MatchContext(appBundleId: "com.example.app", processName: "Example")
        let app = MatchContext(appBundleId: "com.other.app", processName: "Other")
        XCTAssertTrue(contextMatches(rule, app: app))
        XCTAssertTrue(rule.matches(app))
        XCTAssertTrue(rule.matches(nil))
    }

    func testContextFieldsDecodeAsNullWildcards() throws {
        let data = #"{"appBundleId": null, "processName": null}"#.data(using: .utf8)!
        let context = try JSONDecoder().decode(MatchContext.self, from: data)
        XCTAssertNil(context.appBundleId)
        XCTAssertNil(context.processName)
        XCTAssertTrue(contextMatches(context, app: nil))
    }

    func testTriggerRuleCarriesContext() {
        let context = MatchContext(appBundleId: "com.example.app")
        var matcher = TriggerMatcher(rules: [
            TriggerRule(
                trigger: "@@@",
                action: Action(type: "log", message: "hi"),
                context: context
            ),
        ])
        _ = matcher.feed("@")
        _ = matcher.feed("@")
        let hit = matcher.feed("@")
        XCTAssertEqual(hit?.context?.appBundleId, "com.example.app")
    }
}
