enum Focus: Equatable { case nothing, text, composing }

struct Field: Equatable { var token: Int }

struct Snapshot: Equatable {
    var app: String? = nil
    var focus: Focus
    var field: Field? = nil
}

func matches(_ when: When, _ snapshot: Snapshot) -> Bool {
    guard snapshot.focus != .composing else { return false }
    if let apps = when.app {
        guard let app = snapshot.app, apps.contains(app) else { return false }
    }
    return when.focus == .any || snapshot.focus == .text
}

func select(_ candidates: [Rule], _ snapshot: Snapshot) -> Rule? {
    candidates.first { matches($0.when, snapshot) }
}
