import Foundation

/// Buffer capacity for TriggerMatcher, in characters.
/// Triggers longer than this are rejected by loadConfig so no configured
/// rule can silently never match. feed trims the buffer to this size.
public let triggerMaxBuffer = 64

/// Canonical order in a hotkey's description. Shift is not a modifier: it is
/// folded into the key character, so ctrl+shift+a is written ctrl+A.
enum Modifier: String, CaseIterable { case ctrl, alt, cmd }

struct Hotkey: Hashable, CustomStringConvertible {
    var modifiers: Set<Modifier>
    var key: String

    var description: String {
        (Modifier.allCases.filter(modifiers.contains).map(\.rawValue) + [key]).joined(separator: "+")
    }

    /// "ctrl+@", "alt+cmd+x", "ctrl++" (the key is "+").
    static func parse(_ spec: String) throws -> Hotkey {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var key = parts.removeLast()
        if key.isEmpty, parts.last == "" {
            parts.removeLast()
            key = "+"
        }
        guard !key.isEmpty else { throw ConfigError.invalid("empty hotkey key") }
        guard key.count == 1 else { throw ConfigError.invalid("hotkey key must be one character") }
        var modifiers = Set<Modifier>()
        for part in parts {
            switch part {
            case "ctrl", "control": modifiers.insert(.ctrl)
            case "alt", "option": modifiers.insert(.alt)
            case "cmd", "command": modifiers.insert(.cmd)
            case "shift": throw ConfigError.invalid("shift is written in the key (ctrl+A)")
            default: throw ConfigError.invalid("unknown modifier \(part)")
            }
        }
        guard !modifiers.isEmpty else { throw ConfigError.invalid("hotkey needs a modifier") }
        return Hotkey(modifiers: modifiers, key: key)
    }
}

enum Trigger: Equatable, CustomStringConvertible, ExpressibleByStringLiteral {
    case text(String)
    case hotkey(Hotkey)

    init(stringLiteral value: String) { self = .text(value) }

    var description: String {
        switch self {
        case .text(let text): return text
        case .hotkey(let hotkey): return hotkey.description
        }
    }
}

/// One keyboard event as the tap reports it.
enum Input { case char(Character), hotkey(Hotkey) }

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
