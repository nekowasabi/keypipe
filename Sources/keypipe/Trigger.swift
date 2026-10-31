import Foundation

public struct TriggerRule {
    public let trigger: String
    public let action: Action
    public let context: MatchContext?

    public init(trigger: String, action: Action, context: MatchContext? = nil) {
        self.trigger = trigger
        self.action = action
        self.context = context
    }

    public init(_ rule: Rule) {
        self.trigger = rule.trigger
        self.action = rule.action
        self.context = rule.context
    }
}

/// Buffer capacity for TriggerMatcher, in characters.
/// Triggers longer than this are rejected by loadConfig so no configured
/// rule can silently never match. feed trims the buffer to this size.
public let triggerMaxBuffer = 64

public struct TriggerMatcher {
    private let rules: [TriggerRule]
    private let maxBuffer: Int
    private var chars: [Character] = []

    /// Longest trigger wins when several rules match the same buffer.
    /// Ties keep config order. Streaming note: a shorter trigger fires as
    /// soon as its suffix matches, before a longer sibling can complete.
    public init(rules: [TriggerRule], maxBuffer: Int = triggerMaxBuffer) {
        self.rules = rules.enumerated()
            .sorted {
                if $0.element.trigger.count != $1.element.trigger.count {
                    return $0.element.trigger.count > $1.element.trigger.count
                }
                return $0.offset < $1.offset
            }
            .map { $0.element }
        self.maxBuffer = maxBuffer
    }

    public var buffer: String { String(chars) }

    public mutating func reset() {
        chars.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func feed(_ character: Character) -> TriggerRule? {
        chars.append(character)
        if chars.count > maxBuffer {
            chars.removeFirst(chars.count - maxBuffer)
        }
        let current = buffer
        for rule in rules where !rule.trigger.isEmpty {
            if current.hasSuffix(rule.trigger), contextMatches(rule.context, app: nil) {
                return rule
            }
        }
        return nil
    }
}
