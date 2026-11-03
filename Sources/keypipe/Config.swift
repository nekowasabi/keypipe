import Foundation

struct When: Equatable {
    enum Focus: String { case textField, any }
    var focus: Focus = .any
    /// Every other `when` key: one glob term per condition fact, in cost order.
    var conditions = Conditions()

    init(app: [String]? = nil, focus: Focus = .any, facts: [Term] = []) {
        self.focus = focus
        self.conditions = Conditions((app.map { [Term(fact: .app, globs: $0)] } ?? []) + facts)
    }
}

struct Guarded<Value: Equatable>: Equatable {
    var primary: Value
    var onFail: Value? = nil
}

struct Rule: Equatable {
    var trigger: Trigger
    var when: When = When()
    var transform: Guarded<String>? = nil
    var output: Guarded<Output> = Guarded(primary: .builtin(.none))
    /// Pill and transcript label override. nil falls back to the output script or sink name.
    var name: String? = nil
    /// Pill icon: a .app path, an image path, or short text such as an emoji. nil is status-only.
    var icon: String? = nil
}

struct KeypipeConfig: Equatable {
    var rules: [Rule]
    /// Top-level gates: when one entry holds, the fire stops before any rule is looked at and
    /// before any field is read. An entry whose fact cannot be read also stops it (fail safe).
    var deny: [Conditions] = []
    /// Deadline for every shell keypipe runs: transform, output.shell, and their fallbacks.
    var shellTimeout: TimeInterval = 30
    /// Deadline for a whole background job, transform and fallbacks included.
    var backgroundTimeout: TimeInterval = 300
    /// Finished fires show a pill and emit their transcript line. false disables both.
    var hud: Bool = true
}

enum ConfigError: Error, CustomStringConvertible {
    case unreadable(String)
    case invalid(String)

    var description: String {
        switch self {
        case .unreadable(let detail): return "keypipe: cannot read config: \(detail)"
        case .invalid(let detail): return "keypipe: invalid config: \(detail)"
        }
    }
}

func loadConfig(path: String) throws -> KeypipeConfig {
    try loadConfig(data: readConfigData(path: path))
}

func readConfigData(path: String) throws -> Data {
    do { return try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
        throw ConfigError.unreadable(error.localizedDescription)
    }
}

/// The parse itself. A background job parses the bytes its parent loaded, so the rule index
/// it carries always points into the rules the parent matched, even after the file changed.
func loadConfig(data: Data) throws -> KeypipeConfig {
    func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw ConfigError.invalid("expected object")
        }
        if let unknown = Set(object.keys).subtracting(keys).sorted().first {
            throw ConfigError.invalid("unknown key \(unknown)")
        }
        return object
    }
    func nonempty(_ value: Any, name: String) throws -> String {
        guard let string = value as? String else {
            throw ConfigError.invalid("\(name) must be a string")
        }
        guard !string.isEmpty else { throw ConfigError.invalid("empty \(name)") }
        return string
    }
    func nonblank(_ value: Any, name: String) throws -> String {
        let string = try nonempty(value, name: name)
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigError.invalid("empty \(name)")
        }
        return string
    }
    func boolean(_ value: Any, name: String) throws -> Bool {
        #if canImport(Darwin)
            // Why: Darwin's JSONSerialization returns 0 and 1 as NSNumber, which `as? Bool`
            // accepts; only a CFBoolean is a JSON true or false.
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
            else { throw ConfigError.invalid("\(name) must be a boolean") }
            return number.boolValue
        #else
            // Why: swift-corelibs returns JSON numbers as Int or Double, never Bool.
            guard let flag = value as? Bool else {
                throw ConfigError.invalid("\(name) must be a boolean")
            }
            return flag
        #endif
    }
    let json: Any
    do { json = try JSONSerialization.jsonObject(with: data) } catch {
        throw ConfigError.invalid("JSON decoding failed: \(error.localizedDescription)")
    }
    // Why: a fallback runs inside the job (or the sync fire) that already owns the
    // caller's wait, so only a primary output may ask to go to the background.
    func parseOutput(_ value: Any, _ focus: When.Focus, primary: Bool) throws -> Output {
        let output: Output
        if let name = value as? String {
            guard let sink = BuiltinSink(rawValue: name) else {
                throw ConfigError.invalid("unknown output \(name)")
            }
            output = .builtin(sink)
        } else {
            let sink = try object(value, keys: primary ? ["shell", "background"] : ["shell"])
            var background = false
            if let value = sink["background"] {
                background = try boolean(value, name: "background")
            }
            output = .shell(
                ShellOutput(
                    script: try nonempty(sink["shell"] ?? NSNull(), name: "output.shell"),
                    background: background))
        }
        if output.needsTextField && focus != .textField {
            throw ConfigError.invalid("output \(output.name) requires focus textField")
        }
        return output
    }
    /// Every fact key of a `when` or `deny` object: an array of globs.
    func conditions(_ object: [String: Any]) throws -> Conditions {
        var terms: [Term] = []
        for fact in FactName.allCases {
            guard let value = object[fact.rawValue] else { continue }
            guard let globs = value as? [String] else {
                throw ConfigError.invalid("\(fact.rawValue) must be an array of strings")
            }
            // Why: an empty list matches nothing, so a deny entry would silently stop nothing
            // and a rule would never fire; both are mistakes, not intent.
            guard !globs.isEmpty else { throw ConfigError.invalid("empty \(fact.rawValue) list") }
            terms.append(Term(fact: fact, globs: globs))
        }
        return Conditions(terms)
    }
    let root = try object(
        json, keys: ["rules", "deny", "shellTimeout", "backgroundTimeout", "hud"])
    var deny: [Conditions] = []
    if let value = root["deny"] {
        guard let entries = value as? [Any] else {
            throw ConfigError.invalid("deny must be an array")
        }
        deny = try entries.map { entry in
            let entry = try conditions(object(entry, keys: Set(FactName.allCases.map(\.rawValue))))
            // Why: an empty entry would stop every fire.
            guard !entry.terms.isEmpty else { throw ConfigError.invalid("empty deny entry") }
            // Why: deny runs on every fire in every app; a slow fact alone would ask the browser
            // on each keystroke trigger even in a text editor.
            if let slow = entry.terms.first(where: { $0.fact.cost == .slow }), !entry.hasApp {
                throw ConfigError.invalid("deny \(slow.fact.rawValue) requires app")
            }
            return entry
        }
    }
    func seconds(_ name: String, default value: TimeInterval) throws -> TimeInterval {
        guard let raw = root[name] else { return value }
        guard let seconds = raw as? Double, seconds > 0 else {
            throw ConfigError.invalid("\(name) must be positive")
        }
        return seconds
    }
    let shellTimeout = try seconds("shellTimeout", default: 30)
    let backgroundTimeout = try seconds("backgroundTimeout", default: 300)
    var hud = true
    if let value = root["hud"] {
        hud = try boolean(value, name: "hud")
    }
    guard let values = root["rules"] as? [Any] else {
        throw ConfigError.invalid("rules must be an array")
    }
    let rules = try values.map { value -> Rule in
        let entry = try object(
            value,
            keys: ["trigger", "hotkey", "when", "transform", "output", "onFail", "name", "icon"])
        let trigger: Trigger
        switch (entry["trigger"], entry["hotkey"]) {
        case (nil, nil): throw ConfigError.invalid("rule needs trigger or hotkey")
        case (.some, .some): throw ConfigError.invalid("rule has both trigger and hotkey")
        case (.some(let value), nil):
            let text = try nonempty(value, name: "trigger")
            guard text.count <= triggerMaxBuffer else {
                throw ConfigError.invalid(
                    "rule trigger exceeds \(triggerMaxBuffer) characters and can never match")
            }
            trigger = .text(text)
        case (nil, .some(let value)):
            trigger = .hotkey(try Hotkey.parse(try nonempty(value, name: "hotkey")))
        }
        var when = When()
        if let value = entry["when"] {
            let condition = try object(
                value, keys: Set(["focus"] + FactName.allCases.map(\.rawValue)))
            when.conditions = try conditions(condition)
            if let value = condition["focus"] {
                guard let name = value as? String else {
                    throw ConfigError.invalid("focus must be a string")
                }
                guard let focus = When.Focus(rawValue: name) else {
                    throw ConfigError.invalid("unknown focus \(name)")
                }
                when.focus = focus
            }
        }
        var transform = try entry["transform"].map {
            Guarded(primary: try nonempty($0, name: "transform"))
        }
        var output = Guarded(
            primary: try entry["output"].map { try parseOutput($0, when.focus, primary: true) }
                ?? .builtin(.none))
        if let value = entry["onFail"] {
            let fallback = try object(value, keys: ["transform", "output"])
            if let value = fallback["transform"] {
                guard transform != nil else {
                    throw ConfigError.invalid("onFail.transform requires transform")
                }
                transform?.onFail = try nonempty(value, name: "transform")
            }
            if let value = fallback["output"] {
                guard output.primary.canFail else {
                    throw ConfigError.invalid("onFail.output requires an output that can fail")
                }
                output.onFail = try parseOutput(value, when.focus, primary: false)
                if output.primary.isBackground, let fallback = output.onFail, !fallback.detachable {
                    throw ConfigError.invalid(
                        "a background output cannot fall back to \(fallback.name)")
                }
            }
        }
        var name: String? = nil
        if let value = entry["name"] { name = try nonblank(value, name: "name") }
        var icon: String? = nil
        if let value = entry["icon"] { icon = try nonblank(value, name: "icon") }
        return Rule(
            trigger: trigger, when: when, transform: transform, output: output, name: name,
            icon: icon)
    }
    return KeypipeConfig(
        rules: rules, deny: deny, shellTimeout: shellTimeout, backgroundTimeout: backgroundTimeout,
        hud: hud)
}
