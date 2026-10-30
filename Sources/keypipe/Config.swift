import Foundation

public struct Action: Codable, Equatable {
    public var type: String
    public var command: String?
    public var message: String?

    public init(type: String, command: String? = nil, message: String? = nil) {
        self.type = type
        self.command = command
        self.message = message
    }
}

public struct Rule: Codable, Equatable {
    public var trigger: String
    public var action: Action
    public var context: MatchContext?

    public init(trigger: String, action: Action, context: MatchContext? = nil) {
        self.trigger = trigger
        self.action = action
        self.context = context
    }
}

public struct KeypipeConfig: Codable, Equatable {
    public var rules: [Rule]
    public var logPath: String?

    public init(rules: [Rule], logPath: String? = nil) {
        self.rules = rules
        self.logPath = logPath
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case unreadable(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .unreadable(let detail):
            return "keypipe: cannot read config: \(detail)"
        case .invalid(let detail):
            return "keypipe: invalid config: \(detail)"
        }
    }
}

public func loadConfig(path: String) throws -> KeypipeConfig {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw ConfigError.unreadable(error.localizedDescription)
    }
    let config: KeypipeConfig
    do {
        config = try JSONDecoder().decode(KeypipeConfig.self, from: data)
    } catch let error as DecodingError {
        throw ConfigError.invalid("JSON decoding failed: \(error)")
    } catch {
        throw ConfigError.invalid(error.localizedDescription)
    }
    for rule in config.rules {
        if rule.trigger.isEmpty {
            throw ConfigError.invalid("rule trigger must be a non-empty string")
        }
        if rule.trigger.count > triggerMaxBuffer {
            throw ConfigError.invalid(
                "rule trigger exceeds \(triggerMaxBuffer) characters and can never match"
            )
        }
        switch rule.action.type {
        case "shell":
            if (rule.action.command ?? "").isEmpty {
                throw ConfigError.invalid("shell action requires a non-empty command")
            }
        case "log":
            break
        default:
            throw ConfigError.invalid("unknown action type: \(rule.action.type)")
        }
    }
    return config
}
