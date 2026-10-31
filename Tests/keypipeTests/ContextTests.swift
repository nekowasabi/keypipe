import XCTest

@testable import keypipe

final class ContextTests: XCTestCase {
    func testContextFieldsDecodeAsNullWildcards() throws {
        let data = #"{"appBundleId": null, "processName": null}"#.data(using: .utf8)!
        let context = try JSONDecoder().decode(MatchContext.self, from: data)
        XCTAssertNil(context.appBundleId)
        XCTAssertNil(context.processName)
    }
}
