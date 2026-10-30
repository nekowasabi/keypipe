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

public struct TriggerMatcher {
    private let rules: [TriggerRule]
    private let maxBuffer: Int
    private var chars: [Character] = []

    public init(rules: [TriggerRule], maxBuffer: Int = 64) {
        self.rules = rules
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
