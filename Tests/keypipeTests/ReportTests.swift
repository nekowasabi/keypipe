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
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "Fixtures/report-v1.jsonl")
    }

    func testEveryOutcomeRendersTheGoldenLine() throws {
        let lines = try String(contentsOf: Self.fixture, encoding: .utf8).split(separator: "\n")
            .map(String.init)
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

    func testEveryKindOfOutcomeHasAGoldenLine() {
        // Why: a new FireResult case needs a new Kind (kind is an exhaustive switch),
        // and then this fails until the golden file and voice-switch's copy carry it.
        XCTAssertEqual(Set(Self.golden.map(\.0.kind)), Set(Kind.allCases))
    }
}

private enum Kind: CaseIterable {
    case blocked, noMatch, unreadable, noInput, replaced, delivered, started, failed
}

extension FireResult {
    fileprivate var kind: Kind {
        switch self {
        case .blocked: return .blocked
        case .noMatch: return .noMatch
        case .unreadable: return .unreadable
        case .noInput: return .noInput
        case .replaced: return .replaced
        case .delivered: return .delivered
        case .started: return .started
        case .failed: return .failed
        }
    }
}
