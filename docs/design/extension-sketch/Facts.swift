// keypipe/Sources/keypipe/Facts.swift (new; PR2)
//
// Extension point 1 of 2: a *condition fact*. A fact is a named string about the front
// desktop that a rule's `when` (or a `deny` entry) matches with a glob. Adding one is:
//   1. one `case` in FactName,
//   2. one line in `spec`,
//   3. one branch in `readMac`.
// All three switches are exhaustive, so a case without a reader fails the build.
// `when` / `deny` keys are derived from FactName.allCases. No fact name appears in
// Config.swift, Engine.swift, FakeDesktop.swift or LineDesktop.swift.
//
// Deliberately NOT a fact (decision C, 2026-11-01): the focused field's text and the
// selection. Erase, readback and replaceInput keep today's performErase/performWrite
// polling in Engine.swift untouched; the sheet below never reads the field. Input
// sources (selection, M5) are a later design, not this table.

import Foundation

enum FactName: String, CaseIterable {
    case app          // bundle id of the front app        (structural: from Snapshot, free)
    case focus        // "textField" | "any"               (structural; stays the typed When.focus)
    // case url         // front browser tab URL via osascript     (slow)   M4
    // case windowTitle // AXTitle of the front window             (cheap)  M8
    // case ext         // extension of AXDocument                 (cheap)  M9

    var spec: FactSpec {
        switch self {
        case .app:   return FactSpec(cost: .structural)
        case .focus: return FactSpec(cost: .structural)
        // case .url:         return FactSpec(cost: .slow)
        // case .windowTitle: return FactSpec(cost: .cheap)
        }
    }
}

struct FactSpec {
    /// Evaluation order inside one `when`: structural < cheap < slow. Conditions are sorted
    /// by this at parse time and short-circuit, so a slow fact is read only when every
    /// cheaper condition of the same rule already passed.
    enum Cost: Int, Comparable {
        case structural, cheap, slow
        static func < (a: Cost, b: Cost) -> Bool { a.rawValue < b.rawValue }
    }
    var cost: Cost
}

/// The only native grammar: a glob, or any-of globs (fnmatch(3), no FNM_PATHNAME so `*`
/// crosses "/"). Decision: `app` is matched by glob too, so the rule is the same for every
/// fact; a bundle id never contains `* ? [`, so today's exact-match configs keep meaning,
/// and `com.apple.*` becomes writable.
enum Matcher: Equatable {
    case anyOf([String])          // "x" parses as anyOf(["x"])
    func matches(_ value: String) -> Bool { fatalError("not implemented") }
}

/// Reading a fact can fail (Automation denied, osascript timed out, not a browser).
/// Decision: unreadable is NOT "did not match". A rule whose condition names an unreadable
/// fact stops the whole fire with a notification (no fall-through to the next rule of the
/// same trigger); a `deny` entry with an unreadable fact blocks (fail safe).
enum FactRead: Equatable { case value(String), unreadable(reason: String) }

/// `when` and every `deny` entry: [(fact, matcher)] sorted by spec.cost.
struct Conditions: Equatable {
    private(set) var terms: [(FactName, Matcher)]
    init(_ terms: [FactName: Matcher]) { fatalError("not implemented") }
    static func == (a: Conditions, b: Conditions) -> Bool { fatalError("not implemented") }

    enum Verdict: Equatable { case match, noMatch, unreadable(FactName, reason: String) }

    /// Short-circuits in cost order; reads through the sheet only as needed.
    func evaluate(_ sheet: FactSheet) -> Verdict { fatalError("not implemented") }

    /// Config-time rule for `deny` (decision): a slow fact is accepted only next to an
    /// `app` term, so no gate ever asks a browser while a non-browser is in front.
    var hasSlowWithoutApp: Bool { fatalError("not implemented") }
}

/// Condition facts of one fire: lazy, memoized (unreadable is memoized too, so a denied
/// Automation prompt is asked once per fire). Owned by one Engine.fire call on the engine
/// queue. Structural facts come from the Snapshot the fire already took; others call
/// `desktop.fact(_:)` once. Never reads the field text (see header).
final class FactSheet {
    let snapshot: Snapshot
    private let desktop: Desktop
    private var memo: [FactName: FactRead] = [:]
    init(_ desktop: Desktop, _ snapshot: Snapshot) { self.desktop = desktop; self.snapshot = snapshot }
    subscript(_ fact: FactName) -> FactRead { fatalError("not implemented") }
    /// Facts this fire already read, for KEYPIPE_<FACT> (deferred: PR2 exports KEYPIPE_APP only,
    /// exactly as today, so EngineTests' exact environment assertions keep passing).
    func environment() -> [String: String] { ["KEYPIPE_APP": snapshot.app ?? ""] }
}

#if os(macOS)
import ApplicationServices

/// Resolved once per fire by MacDesktop.snapshot and handed to readers.
struct MacFront {
    var pid: pid_t
    var bundleID: String?
    var focused: AXUIElement?
    /// For slow facts implemented as a short-lived process (url: osascript). Reuses Shell.swift.
    /// OPEN (verify on a real machine before PR2): killing osascript at the 1 s deadline while the
    /// first Automation prompt is up may lose the grant. Decision so far: the daemon itself asks
    /// on first use; that fire ends as `unreadable` and notifies "allow keypipe to control <browser>".
    var run: (_ script: String, _ timeout: TimeInterval) -> String?
}

extension FactName {
    /// Exhaustive: adding a case without a reader does not compile.
    func readMac(_ front: MacFront) -> FactRead {
        switch self {
        case .app, .focus: preconditionFailure("structural facts come from Snapshot")
        // case .url:
        //   TODO: switch front.bundleID { Safari: "URL of front document";
        //         Chrome family: "URL of active tab of front window" } via front.run(osascript, 1.0)
        //         nil -> .unreadable("osascript timeout or Automation denied"); non-browser -> .unreadable("not a browser")
        // case .windowTitle: TODO: kAXTitleAttribute of the focused window, nil -> .unreadable
        }
    }
}
#endif
