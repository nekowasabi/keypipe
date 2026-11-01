import Foundation

enum BuiltinSink: String { case none, replaceInput, notify }
enum Output: Equatable {
    case builtin(BuiltinSink), shell(ShellOutput)

    var isBackground: Bool {
        if case .shell(let shell) = self { return shell.background }
        return false
    }
}

/// background: the caller returns at once and a detached job runs transform and output.
struct ShellOutput: Equatable, ExpressibleByStringLiteral {
    var script: String
    var background = false

    init(script: String, background: Bool = false) {
        self.script = script
        self.background = background
    }

    init(stringLiteral script: String) { self.init(script: script) }
}

struct When: Equatable {
    enum Focus: String { case textField, any }
    var app: [String]? = nil
    var focus: Focus = .any
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
}

struct KeypipeConfig: Equatable {
    var rules: [Rule]
    /// Deadline for every shell keypipe runs: transform, output.shell, and their fallbacks.
    var shellTimeout: TimeInterval = 30
    /// Deadline for a whole background job, transform and fallbacks included.
    var backgroundTimeout: TimeInterval = 300
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
    do { return try Data(contentsOf: URL(fileURLWithPath: path)) }
    catch { throw ConfigError.unreadable(error.localizedDescription) }
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
    let json: Any
    do { json = try JSONSerialization.jsonObject(with: data) }
    catch { throw ConfigError.invalid("JSON decoding failed: \(error.localizedDescription)") }
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
                guard let flag = value as? Bool else { throw ConfigError.invalid("background must be a boolean") }
                background = flag
            }
            output = .shell(ShellOutput(script: try nonempty(sink["shell"] ?? NSNull(), name: "output.shell"),
                                        background: background))
        }
        if output == .builtin(.replaceInput) && focus != .textField {
            throw ConfigError.invalid("output replaceInput requires focus textField")
        }
        return output
    }
    let root = try object(json, keys: ["rules", "shellTimeout", "backgroundTimeout"])
    func seconds(_ name: String, default value: TimeInterval) throws -> TimeInterval {
        guard let raw = root[name] else { return value }
        guard let seconds = raw as? Double, seconds > 0 else {
            throw ConfigError.invalid("\(name) must be positive")
        }
        return seconds
    }
    let shellTimeout = try seconds("shellTimeout", default: 30)
    let backgroundTimeout = try seconds("backgroundTimeout", default: 300)
    guard let values = root["rules"] as? [Any] else {
        throw ConfigError.invalid("rules must be an array")
    }
    let rules = try values.map { value -> Rule in
        let entry = try object(value, keys: ["trigger", "hotkey", "when", "transform", "output", "onFail"])
        let trigger: Trigger
        switch (entry["trigger"], entry["hotkey"]) {
        case (nil, nil): throw ConfigError.invalid("rule needs trigger or hotkey")
        case (.some, .some): throw ConfigError.invalid("rule has both trigger and hotkey")
        case (.some(let value), nil):
            let text = try nonempty(value, name: "trigger")
            guard text.count <= triggerMaxBuffer else {
                throw ConfigError.invalid("rule trigger exceeds \(triggerMaxBuffer) characters and can never match")
            }
            trigger = .text(text)
        case (nil, .some(let value)):
            trigger = .hotkey(try Hotkey.parse(try nonempty(value, name: "hotkey")))
        }
        var when = When()
        if let value = entry["when"] {
            let condition = try object(value, keys: ["app", "focus"])
            if let value = condition["app"] {
                guard let apps = value as? [String] else {
                    throw ConfigError.invalid("app must be an array of strings")
                }
                when.app = apps
            }
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
        var output = Guarded(primary: try entry["output"].map { try parseOutput($0, when.focus, primary: true) } ?? .builtin(.none))
        if let value = entry["onFail"] {
            let fallback = try object(value, keys: ["transform", "output"])
            if let value = fallback["transform"] {
                guard transform != nil else { throw ConfigError.invalid("onFail.transform requires transform") }
                transform?.onFail = try nonempty(value, name: "transform")
            }
            if let value = fallback["output"] {
                guard output.primary != .builtin(.none), output.primary != .builtin(.notify) else {
                    throw ConfigError.invalid("onFail.output requires an output that can fail")
                }
                output.onFail = try parseOutput(value, when.focus, primary: false)
                if output.primary.isBackground && output.onFail == .builtin(.replaceInput) {
                    throw ConfigError.invalid("a background output cannot fall back to replaceInput")
                }
            }
        }
        return Rule(trigger: trigger, when: when, transform: transform, output: output)
    }
    return KeypipeConfig(rules: rules, shellTimeout: shellTimeout, backgroundTimeout: backgroundTimeout)
}
