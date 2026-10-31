import Foundation

/// Buffer capacity for TriggerMatcher, in characters.
/// Triggers longer than this are rejected by loadConfig so no configured
/// rule can silently never match. feed trims the buffer to this size.
public let triggerMaxBuffer = 64

public struct TriggerMatcher {
    private let triggers: [String]
    private let maxBuffer: Int
    private var chars: [Character] = []

    /// Longest trigger wins when several rules match the same buffer.
    /// Ties keep config order. Streaming note: a shorter trigger fires as
    /// soon as its suffix matches, before a longer sibling can complete.
    public init(triggers: [String], maxBuffer: Int = triggerMaxBuffer) {
        self.triggers = triggers.enumerated()
            .sorted {
                if $0.element.count != $1.element.count {
                    return $0.element.count > $1.element.count
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
    public mutating func feed(_ character: Character) -> String? {
        chars.append(character)
        if chars.count > maxBuffer {
            chars.removeFirst(chars.count - maxBuffer)
        }
        let current = buffer
        for trigger in triggers where !trigger.isEmpty {
            if current.hasSuffix(trigger) {
                return trigger
            }
        }
        return nil
    }
}
