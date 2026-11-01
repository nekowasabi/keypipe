import XCTest

@testable import keypipe

/// P1: --report renders each FireResult case to exactly one golden line, and --line's exit
/// code is the projection isHit. voice-switch decodes a copy of the same golden file.
final class ReportTests: XCTestCase {
    static let golden: [(FireResult, Bool)] = [
        (.blocked("terminal"), false),
        (.noMatch, false),
        (.unreadable(fact: "url", reason: "timeout"), false),
        (.noInput(rule: 0), true),
        (.replaced(rule: 1, text: "お世話になっております。\n\"引用\" $(x) `y`", viaFallback: false), true),
        (.replaced(rule: 0, text: "HELLO", viaFallback: true), true),
        (.delivered(rule: 2, viaFallback: false), true),
        (.delivered(rule: 0, viaFallback: true), true),
        (.started(rule: 3), true),
        (.failed(rule: 0, stage: .transform, failure: "exit 1"), true),
        (.failed(rule: 0, stage: .output, failure: "unsupported"), true),
        (.failed(rule: 4, stage: .spawn, failure: "spawn"), true),
    ]

    static var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/report-v1.jsonl")
    }

    func testEveryOutcomeRendersTheGoldenLine() throws {
        let lines = try String(contentsOf: Self.fixture, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, Self.golden.count, "one golden line per case")
        for ((result, _), line) in zip(Self.golden, lines) {
            XCTAssertEqual(result.reportJSON, line)
        }
    }

    func testHitIsWhatLineExitsZeroOn() {
        for (result, hit) in Self.golden {
            XCTAssertEqual(result.isHit, hit, "\(result)")
        }
    }

    func testEveryCaseIsInTheGoldenList() {
        // Why: a new FireResult case must get a golden line, or voice-switch will not know it.
        var kinds = Set<String>()
        for (result, _) in Self.golden {
            switch result {
            case .blocked: kinds.insert("blocked")
            case .noMatch: kinds.insert("noMatch")
            case .unreadable: kinds.insert("unreadable")
            case .noInput: kinds.insert("noInput")
            case .replaced: kinds.insert("replaced")
            case .delivered: kinds.insert("delivered")
            case .started: kinds.insert("started")
            case .failed: kinds.insert("failed")
            }
        }
        XCTAssertEqual(kinds.count, 8)
    }
}
