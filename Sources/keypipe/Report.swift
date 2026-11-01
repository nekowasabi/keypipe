import Foundation

/// `keypipe --line <trigger> --report`: one JSON line describing what the fire did.
/// The schema is versioned by "v". Additions keep v=1; a removed or renamed key bumps it.
/// Tests/keypipeTests/Fixtures/report-v1.jsonl holds one line per outcome, and voice-switch
/// decodes a copy of that file, so a drift on either side fails a test.
extension FireResult {
    var reportJSON: String {
        var object: [String: Any] = ["v": 1]
        switch self {
        case .blocked(let word):
            object["outcome"] = "blocked"
            object["reason"] = word
        case .noMatch:
            object["outcome"] = "nomatch"
        case .unreadable(let fact, let reason):
            object["outcome"] = "unreadable"
            object["fact"] = fact
            object["reason"] = reason
        case .noInput(let rule):
            object["outcome"] = "noinput"
            object["rule"] = rule
        case .replaced(let rule, let text, let viaFallback):
            object["outcome"] = "replaced"
            object["rule"] = rule
            object["text"] = text
            if viaFallback { object["fallback"] = true }
        case .delivered(let rule, let viaFallback):
            object["outcome"] = "delivered"
            object["rule"] = rule
            if viaFallback { object["fallback"] = true }
        case .started(let rule):
            object["outcome"] = "started"
            object["rule"] = rule
        case .failed(let rule, let stage, let failure):
            object["outcome"] = "failed"
            object["rule"] = rule
            object["stage"] = stage.rawValue
            object["failure"] = failure
        }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
