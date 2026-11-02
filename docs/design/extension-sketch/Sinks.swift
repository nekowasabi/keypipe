// keypipe/Sources/keypipe/Sinks.swift (new; PR3. Takes BuiltinSink out of Config.swift and
// the per-sink switch out of Engine.apply)
//
// Extension point 2 of 2: a native output. Adding one is one case + one `spec` line + one
// `perform` branch, here only. parseOutput and Engine.apply read `spec` / call `perform`
// and never name a sink. Everything else stays `{"shell": ...}`.

import Foundation

/// Why a stage failed. Token = transcript word = KEYPIPE_FAILURE. (Moved from Engine.swift.)
enum Failure: Error, Equatable {
    case exit(Int32), timeout, empty, ignored, gone
    case unsupported          // new: the sink cannot act on this Desktop (typeText via --line)
    var token: String { fatalError("not implemented") }
    var kind: FailureKind { fatalError("not implemented") }
}
enum FailureKind: Hashable { case exit, timeout, empty, ignored, gone, unsupported }

enum Sink: String, CaseIterable {
    case none, replaceInput, notify
    // case typeText   // M17

    var spec: SinkSpec {
        switch self {
        case .none:         return SinkSpec(failures: [])
        case .notify:       return SinkSpec(failures: [])
        case .replaceInput: return SinkSpec(failures: [.ignored, .gone], needsTextField: true, detachable: false)
        // case .typeText:  return SinkSpec(failures: [.gone, .unsupported], detachable: false)
        //   Native, not shell: keypipe tags its own key events (keypipeEventTag) so its tap drops
        //   them; `osascript keystroke` from a shell is untagged and would re-enter the matcher.
        }
    }

    /// The whole side effect. Emits nothing: Engine writes the uniform transcript line
    /// "keypipe [fallback ]apply <rawValue> <json>" / "apply-failed <rawValue> <token>" (today's strings).
    /// replaceInput keeps calling today's performWrite (readback polling) untouched.
    func perform(_ text: String, field: Field?, _ desktop: Desktop) -> Failure? {
        switch self {
        case .none: return nil
        case .notify: fatalError("not implemented")        // desktop.notify(text)
        case .replaceInput: fatalError("not implemented")  // performWrite(field, text, desktop) as today
        // case .typeText:
        //   Decision (a): a Desktop that cannot type (LineDesktop: zsh line, voice) returns
        //   .unsupported, so --report says failed and onFail can route to notify. Never a fake success.
        //   TODO: desktop.typeText(text) ? nil : .unsupported
        }
    }
}

struct SinkSpec {
    /// Failure kinds perform may return. Empty = cannot fail, so onFail.output is rejected (today's rule).
    var failures: Set<FailureKind>
    /// Requires `when.focus: textField` (today's "replaceInput requires focus textField", now derived).
    var needsTextField = false
    /// May run inside a detached background job. false rejects it as a background fallback (today's rule).
    var detachable = true
    var canFail: Bool { !failures.isEmpty }
}

struct ShellOutput: Equatable { var script: String; var background = false }

enum Output: Equatable {
    case native(Sink), shell(ShellOutput)
    var failures: Set<FailureKind> { fatalError("not implemented") }   // shell: [.exit, .timeout]
    var detachable: Bool { fatalError("not implemented") }
    var needsTextField: Bool { fatalError("not implemented") }
    var isBackground: Bool { fatalError("not implemented") }
}
