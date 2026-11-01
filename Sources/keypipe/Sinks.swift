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
        case .none: return SinkSpec(failures: [])
        case .notify: return SinkSpec(failures: [])
        case .replaceInput:
            return SinkSpec(
                failures: [.ignored, .gone], needsTextField: true, writesField: true,
                detachable: false)
        case .typeText: return SinkSpec(failures: [.unsupported], detachable: false)
        }
    }

    /// The side effect. nil on success. Emits nothing: Engine writes the transcript line.
    func perform(_ text: String, field: Field?, _ desktop: Desktop) -> Failure? {
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
            return desktop.typeText(text) ? nil : .unsupported
        }
    }
}

/// What config validation and the engine need to know about a native output.
struct SinkSpec {
    /// The failures `perform` can return. Empty means it cannot fail, so `onFail.output` is refused.
    var failures: Set<Failure>
    /// Writes the field it read, so the rule needs `focus: textField`.
    var needsTextField = false
    /// Success is reported as `replaced` with the text, not `delivered`.
    var writesField = false
    /// May run as the fallback of a background output (a job has no field and no caret).
    var detachable = true

    var canFail: Bool { !failures.isEmpty }
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
