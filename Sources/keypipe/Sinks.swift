import Foundation

/// A native output. Adding one is one case, one line in `spec`, and one branch in `perform`,
/// here only: config validation and Engine.apply read `spec` and call `perform`, and never
/// name a sink. Everything else stays `{"shell": ...}`.
enum BuiltinSink: String, CaseIterable {
    case none, replaceInput, notify
    /// Types the result at the caret with tagged key events (the tap drops them, so the text
    /// never re-enters the trigger matcher). On the --line path there is nothing to type into,
    /// so it fails with `unsupported` instead of reporting a success.
    case typeText

    var spec: SinkSpec {
        switch self {
        case .none, .notify: return SinkSpec(canFail: false)
        case .replaceInput:
            return SinkSpec(
                canFail: true, needsTextField: true, writesField: true, detachable: false)
        case .typeText: return SinkSpec(canFail: true, detachable: false)
        }
    }

    /// The side effect. nil on success. Emits nothing: Engine writes the transcript line.
    /// `origin` is the snapshot the fire's gates passed on; nil for a job.
    func perform(_ text: String, origin: Snapshot?, _ desktop: Desktop) -> Failure? {
        let field = origin?.field
        switch self {
        case .none: return nil
        case .notify:
            desktop.notify(text)
            return nil
        case .replaceInput:
            switch field.map({ performWrite($0, text, desktop) }) ?? .gone {
            case .written: return nil
            case .ignored: return .ignored
            case .gone: return .gone
            }
        case .typeText:
            // Why: a transform can take seconds, and the keys go to whatever is in front then. deny,
            // the terminal gate and the password gate held only for the front at the fire.
            guard let origin, origin.isStillFront(desktop.snapshot(), desktop) else { return .gone }
            return desktop.typeText(text) ? nil : .unsupported
        }
    }
}

extension Snapshot {
    /// `now` has the same app, kind of focus and field as this one, and no password field.
    func isStillFront(_ now: Snapshot, _ desktop: Desktop) -> Bool {
        guard now.app == app, now.focus == focus, !now.secure else { return false }
        switch (field, now.field) {
        case (nil, nil): return true
        case (let before?, let after?): return desktop.sameField(before, after)
        default: return false
        }
    }
}

/// What config validation and the engine need to know about a native output.
struct SinkSpec {
    /// `perform` can return a failure. false means `onFail.output` is refused.
    var canFail: Bool
    /// Writes the field it read, so the rule needs `focus: textField`.
    var needsTextField = false
    /// Success is reported as `replaced` with the text, not `delivered`.
    var writesField = false
    /// May run as the fallback of a background output (a job has no field and no caret).
    var detachable = true
}

enum Output: Equatable {
    case builtin(BuiltinSink)
    case shell(ShellOutput)

    var isBackground: Bool {
        if case .shell(let shell) = self { return shell.background }
        return false
    }

    var name: String {
        switch self {
        case .builtin(let sink): return sink.rawValue
        case .shell: return "output.shell"
        }
    }

    /// A shell can always fail (exit status, timeout).
    var canFail: Bool {
        if case .builtin(let sink) = self { return sink.spec.canFail }
        return true
    }

    var needsTextField: Bool {
        if case .builtin(let sink) = self { return sink.spec.needsTextField }
        return false
    }

    var writesField: Bool {
        if case .builtin(let sink) = self { return sink.spec.writesField }
        return false
    }

    var detachable: Bool {
        if case .builtin(let sink) = self { return sink.spec.detachable }
        return true
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
