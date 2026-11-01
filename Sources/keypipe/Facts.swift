import Foundation

#if canImport(Glibc)
    import Glibc
#endif

/// A condition fact: a named string about the front desktop that a rule's `when`, or a
/// top-level `deny` entry, matches with globs. Adding one is one case here, one line in
/// `cost`, and one branch in the Mac reader (MacDesktop.fact). The `when` and `deny` keys
/// and the fake context's `facts` keys are derived from `allCases`; no other file names a fact.
///
/// Deliberately not a fact: the focused field's text. Erase, readback and replaceInput keep
/// polling `Desktop.text(_:)` in Engine.swift, and a sheet never reads it, so a gate or a
/// condition can never see the field.
enum FactName: String, CaseIterable {
    /// Bundle id of the front app. Comes with the snapshot, so it costs nothing.
    case app
    /// URL of the front browser tab, read through osascript: slow, and macOS asks for
    /// Automation permission the first time.
    case url

    var cost: FactCost {
        switch self {
        case .app: return .structural
        case .url: return .slow
        }
    }
}

/// Evaluation order inside one condition list: structural < cheap < slow.
enum FactCost: Int, Comparable {
    case structural, cheap, slow
    static func < (a: FactCost, b: FactCost) -> Bool { a.rawValue < b.rawValue }
}

/// What reading a fact gave.
enum FactRead: Equatable {
    case value(String)
    /// There is no such thing here (the front app is not a browser): the condition does not hold.
    case absent
    /// It exists but could not be read (Automation denied, osascript timed out).
    case unreadable(String)
}

/// One condition: any of the globs matches the fact (fnmatch(3) without FNM_PATHNAME, so `*`
/// crosses "/"). A bundle id never contains `* ? [`, so an exact id is still an exact match.
struct Term: Equatable {
    var fact: FactName
    var globs: [String]

    func matches(_ value: String) -> Bool {
        globs.contains { fnmatch($0, value, 0) == 0 }
    }
}

/// A `when` (without focus) or one `deny` entry, kept in cost order so a slow fact is read only
/// after every cheaper term of the same list matched.
struct Conditions: Equatable {
    private(set) var terms: [Term]

    init(_ terms: [Term] = []) {
        self.terms = terms.enumerated()
            .sorted { ($0.element.fact.cost, $0.offset) < ($1.element.fact.cost, $1.offset) }
            .map(\.element)
    }

    enum Verdict: Equatable { case match, noMatch, unreadable(FactName, String) }

    /// Short-circuits in cost order: the first term that does not match decides.
    func evaluate(_ sheet: FactSheet) -> Verdict {
        for term in terms {
            switch sheet[term.fact] {
            case .value(let value): if !term.matches(value) { return .noMatch }
            case .absent: return .noMatch
            case .unreadable(let reason): return .unreadable(term.fact, reason)
            }
        }
        return .match
    }

    var hasSlowTerm: Bool { terms.contains { $0.fact.cost == .slow } }
    var hasApp: Bool { terms.contains { $0.fact == .app } }
}

/// The condition facts of one fire: read lazily, at most once each (an unreadable read is kept
/// too, so a denied Automation prompt is not asked twice in one fire). Owned by one fire.
final class FactSheet {
    let snapshot: Snapshot
    private let desktop: Desktop?
    private var memo: [FactName: FactRead] = [:]
    private(set) var readSlow = false

    init(_ snapshot: Snapshot, desktop: Desktop?) {
        self.snapshot = snapshot
        self.desktop = desktop
    }

    subscript(_ fact: FactName) -> FactRead {
        if fact == .app { return snapshot.app.map(FactRead.value) ?? .absent }
        if let known = memo[fact] { return known }
        let read = desktop?.fact(fact) ?? .absent
        if fact.cost == .slow { readSlow = true }
        memo[fact] = read
        return read
    }
}
