// keypipe/Sources/keypipe/Config.swift (changed in PR2 and PR3)
//
// `When` stays a type (tests build When(focus:) directly: EngineTests, ContextTests), with
// `focus` as today's typed enum, so "unknown focus window" is still rejected with today's
// message (ConfigTests.swift:36, verify-keypipe-rules R2f). Only the fact terms are added.
//
// Accepted key sets: structure keys are literal lists owned by this file; vocabulary is derived.
//   when keys          = ["focus"] + FactName.allCases.map(\.rawValue) minus "focus"
//   deny entry keys    = same
//   native output names= Sink.allCases.map(\.rawValue)          (PR3)
// Unknown keys are rejected as today ("unknown key url" before PR M4, accepted after).

import Foundation

struct When: Equatable {
    enum Focus: String { case textField, any }
    var focus: Focus = .any
    /// PR2: `app` moves in here as Conditions term .app (glob), plus url / windowTitle / ...
    /// `When(app: [...])` keeps an init for the existing tests and is equivalent to a literal glob.
    var conditions: Conditions = Conditions([:])
}

struct Rule: Equatable {
    var trigger: Trigger
    var when: When = When()
    var transform: Guarded<String>? = nil
    var output: Guarded<Output>
}

struct Guarded<Value: Equatable>: Equatable { var primary: Value; var onFail: Value? = nil }

struct KeypipeConfig: Equatable {
    var rules: [Rule]
    /// M6 (PR2). Each entry is a `when`-shaped object; a match (or an unreadable fact) blocks the
    /// fire before any rule. Built-in gates (composing, terminal, secure) always run first.
    var deny: [Conditions] = []
    var shellTimeout: TimeInterval = 30
    var backgroundTimeout: TimeInterval = 300
}

func loadConfig(path: String) throws -> KeypipeConfig { fatalError("not implemented") }
/// Same parse from bytes, for the background child (JobRequest.configBytes).
func loadConfig(data: Data, path: String) throws -> KeypipeConfig { fatalError("not implemented") }

// TODO root keys: ["rules", "deny", "shellTimeout", "backgroundTimeout"]
// TODO rule keys: ["trigger", "hotkey", "when", "transform", "output", "onFail"]   (unchanged)

/// `{"app": [...], "focus": "textField", "url": "*://github.com/*"}` -> When.
/// "focus" is parsed into the typed enum (value check mandatory, today's message); every other
/// key must be a FactName, value a string or array of strings (glob).
func parseWhen(_ value: Any) throws -> When { fatalError("not implemented") }

/// `deny` entries: parseWhen without "focus", plus the decision rule
///   "a slow fact in deny needs an app term" -> ConfigError.invalid("deny url requires app").
func parseDeny(_ value: Any) throws -> [Conditions] { fatalError("not implemented") }

/// PR3. Every output rule derives from SinkSpec / Output:
///   needsTextField     -> when.focus == .textField        ("output replaceInput requires focus textField", verbatim)
///   onFail.output      -> primary.failures non-empty      ("onFail.output requires an output that can fail")
///   background fallback-> fallback.detachable             ("a background output cannot fall back to replaceInput")
///   `background` key   -> only on a primary {"shell": ...} (unchanged)
func parseOutput(_ value: Any, _ focus: When.Focus, primary: Bool) throws -> Output { fatalError("not implemented") }
