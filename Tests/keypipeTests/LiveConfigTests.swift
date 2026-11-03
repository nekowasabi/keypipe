import XCTest

@testable import keypipe

final class LiveConfigTests: XCTestCase {
    private var path: String!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "keypipe-live-\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
    }

    func testAnEditAppliesOnceAndABrokenEditKeepsTheRunningRules() throws {
        let one = #"{"rules":[{"trigger":"@@@","output":"notify"}]}"#
        try write(one)
        var live = LiveConfig(path: path, bytes: Data(one.utf8))
        var reports: [String] = []
        XCTAssertNil(live.poll { reports.append($0) }, "unchanged file: nothing to reload")

        let two = #"{"rules":[{"trigger":"@@@","output":"notify"},{"trigger":";;;"}]}"#
        try write(two)
        XCTAssertEqual(live.poll { reports.append($0) }?.rules.count, 2)
        XCTAssertEqual(live.bytes, Data(two.utf8), "a job is handed the rules that now run")
        XCTAssertNil(live.poll { reports.append($0) }, "the same edit is not reloaded twice")

        try write(#"{"rules":[{"trigger":"@@@","name":""}]}"#)
        XCTAssertNil(live.poll { reports.append($0) })
        XCTAssertNil(live.poll { reports.append($0) })
        XCTAssertEqual(reports, ["keypipe: invalid config: empty name"], "reported once")
        XCTAssertEqual(live.bytes, Data(two.utf8), "the running rules stay")

        try FileManager.default.removeItem(atPath: path)
        XCTAssertNil(live.poll { reports.append($0) }, "a save that briefly removes the file")

        try write(one)
        XCTAssertEqual(live.poll { reports.append($0) }?.rules.count, 1)
        XCTAssertEqual(reports.count, 1)
    }
}
