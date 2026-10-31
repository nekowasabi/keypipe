import Foundation

enum BuiltinSink: String { case none, replaceInput, notify }
enum Output: Equatable { case builtin(BuiltinSink), shell(String) }

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
    var trigger: String
    var when: When = When()
    var transform: Guarded<String>? = nil
    var output: Guarded<Output> = Guarded(primary: .builtin(.none))
}

struct KeypipeConfig: Equatable {
    var rules: [Rule]
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
    let data: Data
    do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
    catch { throw ConfigError.unreadable(error.localizedDescription) }

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
    let root = try object(json, keys: ["rules"])
    guard let values = root["rules"] as? [Any] else {
        throw ConfigError.invalid("rules must be an array")
    }
    let rules = try values.map { value -> Rule in
        let entry = try object(value, keys: ["trigger", "when", "transform", "output"])
        let trigger = try nonempty(entry["trigger"] ?? NSNull(), name: "trigger")
        guard trigger.count <= triggerMaxBuffer else {
            throw ConfigError.invalid("rule trigger exceeds \(triggerMaxBuffer) characters and can never match")
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
        let transform = try entry["transform"].map {
            Guarded(primary: try nonempty($0, name: "transform"))
        }
        var output: Output = .builtin(.none)
        if let value = entry["output"] {
            if let name = value as? String {
                guard let sink = BuiltinSink(rawValue: name) else {
                    throw ConfigError.invalid("unknown output \(name)")
                }
                output = .builtin(sink)
            } else {
                let sink = try object(value, keys: ["shell"])
                output = .shell(try nonempty(sink["shell"] ?? NSNull(), name: "output.shell"))
            }
        }
        if output == .builtin(.replaceInput) && when.focus != .textField {
            throw ConfigError.invalid("output replaceInput requires focus textField")
        }
        return Rule(trigger: trigger, when: when, transform: transform, output: Guarded(primary: output))
    }
    return KeypipeConfig(rules: rules)
}
