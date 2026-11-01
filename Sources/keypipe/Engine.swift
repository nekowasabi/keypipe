import Foundation

func jsonString(_ text: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

/// Why a stage failed. The token is both the transcript word and KEYPIPE_FAILURE.
enum Failure: Error, Equatable {
    case exit(Int32), timeout, empty, ignored, gone

    var token: String {
        switch self {
        case .exit(let status): return "exit \(status)"
        case .timeout: return "timeout"
        case .empty: return "empty"
        case .ignored: return "ignored"
        case .gone: return "gone"
        }
    }
}

/// Field text once the trigger has landed, or the latest text after 100 ms.
/// Why: the tap sees the last trigger key before the app has appended it;
/// erasing then would remove text typed before the trigger.
func waitForTrigger(_ field: Field, _ trigger: String, _ desktop: Desktop) -> String? {
    guard var text = desktop.text(field) else { return nil }
    let deadline = ProcessInfo.processInfo.systemUptime + 0.1
    while !text.hasSuffix(trigger) && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.005)
        guard let current = desktop.text(field) else { return nil }
        text = current
    }
    return text
}

/// Erases the trigger and returns the field text to use as input. nil means the
/// field is gone. Erase failures other than that are reported and carried on,
/// so a slow transform's result is never thrown away over a stray trigger.
func performErase(_ field: Field, trigger: String, _ desktop: Desktop, emit: (String) -> Void) -> String? {
    guard let before = waitForTrigger(field, trigger, desktop) else { return nil }
    desktop.backspace(trigger.count)
    emit("keypipe erase \(trigger.count)")
    guard before.hasSuffix(trigger) else {
        emit("keypipe erase-failed trigger-absent")
        return desktop.text(field)
    }
    let expected = String(before.dropLast(trigger.count))
    let deadline = ProcessInfo.processInfo.systemUptime + 0.2
    var after = desktop.text(field)
    // Why: Backspaces are delivered one key event at a time; reading after the first
    // one lands would hand a partially erased trigger to the transform, and a rewrite
    // issued then would be undone by the Backspaces still in flight.
    while after != expected && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.005)
        after = desktop.text(field)
    }
    guard let current = after else { return nil }
    guard current == before else { return current }
    guard desktop.setText(field, expected), let rewritten = desktop.text(field) else { return nil }
    if rewritten == expected {
        emit("keypipe erase-rewrite")
    } else {
        emit("keypipe erase-failed rewrite-ignored")
    }
    return rewritten
}

enum WriteOutcome: Equatable { case written, ignored, gone }

func performWrite(_ field: Field, _ text: String, _ desktop: Desktop) -> WriteOutcome {
    guard desktop.setText(field, text), let readback = desktop.text(field) else { return .gone }
    return readback == text ? .written : .ignored
}

struct Engine {
    private let config: KeypipeConfig
    private let desktop: Desktop
    private let shell: (String, String, [String: String], TimeInterval) -> ShellOutcome
    private let emit: (String) -> Void
    private var matcher: TriggerMatcher
    private let hotkeys: Set<Hotkey>
    private(set) var hits = 0

    init(config: KeypipeConfig, desktop: Desktop,
         shell: @escaping (String, String, [String: String], TimeInterval) -> ShellOutcome,
         emit: @escaping (String) -> Void) {
        self.config = config
        self.desktop = desktop
        self.shell = shell
        self.emit = emit
        var texts: [String] = []
        var hotkeys = Set<Hotkey>()
        for rule in config.rules {
            switch rule.trigger {
            case .text(let text): texts.append(text)
            case .hotkey(let hotkey): hotkeys.insert(hotkey)
            }
        }
        self.matcher = TriggerMatcher(triggers: texts)
        self.hotkeys = hotkeys
    }

    mutating func key(_ character: Character) {
        guard let text = matcher.feed(character) else { return }
        matcher.reset()
        fire(.text(text))
    }

    /// A chord breaks any text sequence in progress. Unconfigured chords
    /// (Cmd+C, Cmd+Tab) return before touching the desktop.
    mutating func hotkey(_ hotkey: Hotkey) {
        matcher.reset()
        guard hotkeys.contains(hotkey) else { return }
        fire(.hotkey(hotkey))
    }

    private mutating func fire(_ trigger: Trigger) {
        let snapshot = desktop.snapshot()
        guard snapshot.focus != .composing else {
            emit("keypipe composing \(trigger)")
            return
        }
        guard let rule = select(config.rules.filter { $0.trigger == trigger }, snapshot),
              let index = config.rules.firstIndex(of: rule) else {
            emit("keypipe nomatch \(trigger)")
            return
        }
        hits += 1
        emit("keypipe matched \(trigger) rule \(index)")
        let input: String
        switch (trigger, rule.when.focus) {
        case (.text(let text), .textField):
            guard let field = snapshot.field,
                  let erased = performErase(field, trigger: text, desktop, emit: emit) else { return }
            input = erased
        case (.hotkey, .textField):
            emit("keypipe erase 0")
            guard let field = snapshot.field, let current = desktop.text(field) else { return }
            input = current
        case (.text(let text), .any):
            let count = snapshot.focus == .text ? text.count : 0
            if count > 0, let field = snapshot.field {
                _ = waitForTrigger(field, text, desktop)
                desktop.backspace(count)
            }
            emit("keypipe erase \(count)")
            input = ""
        case (.hotkey, .any):
            emit("keypipe erase 0")
            input = ""
        }
        let environment = ["KEYPIPE_APP": snapshot.app ?? ""]
        var result = input
        if let transform = rule.transform {
            switch runTransform(transform, input, environment) {
            case .success(let output): result = output
            case .failure(let failure):
                notify("\(trigger) transform failed: \(failure.token)")
                return
            }
        }
        guard let failure = apply(rule.output.primary, result, environment, snapshot.field, prefix: "") else { return }
        guard let fallback = rule.output.onFail else {
            // Why: without a fallback the text must not be lost, and a shell's own
            // failure is already visible in the transcript.
            if rule.output.primary == .builtin(.replaceInput) { notify(result) }
            return
        }
        var environment2 = environment
        environment2["KEYPIPE_FAILURE"] = failure.token
        if let second = apply(fallback, result, environment2, snapshot.field, prefix: "fallback ") {
            notify("\(trigger) output failed: \(second.token)")
        }
    }

    /// Primary once, then onFail once with the same input and KEYPIPE_FAILURE set.
    private func runTransform(_ transform: Guarded<String>, _ input: String, _ env: [String: String])
        -> Result<String, Failure>
    {
        switch shellStage(transform.primary, input, env, prefix: "", stage: "transform") {
        case .success(let output): return .success(output)
        case .failure(let failure):
            guard let fallback = transform.onFail else { return .failure(failure) }
            var env = env
            env["KEYPIPE_FAILURE"] = failure.token
            return shellStage(fallback, input, env, prefix: "fallback ", stage: "transform")
        }
    }

    private func shellStage(_ script: String, _ input: String, _ env: [String: String], prefix: String, stage: String)
        -> Result<String, Failure>
    {
        switch shell(script, input, env, config.shellTimeout) {
        case .exited(let status, let output):
            emit("keypipe \(prefix)\(stage) exit \(status)")
            guard status == 0 else { return .failure(.exit(status)) }
            if stage == "transform" && output.isEmpty {
                // Why: an empty result would wipe the field through replaceInput.
                emit("keypipe \(prefix)\(stage) empty")
                return .failure(.empty)
            }
            return .success(output)
        case .timedOut(let seconds):
            emit("keypipe \(prefix)\(stage) timeout \(seconds)")
            return .failure(.timeout)
        }
    }

    /// nil on success. notify and none cannot fail.
    private func apply(_ output: Output, _ result: String, _ env: [String: String], _ field: Field?, prefix: String)
        -> Failure?
    {
        switch output {
        case .builtin(.replaceInput):
            let outcome = field.map { performWrite($0, result, desktop) } ?? .gone
            switch outcome {
            case .written:
                emit("keypipe \(prefix)apply replaceInput \(jsonString(result))")
                return nil
            case .ignored:
                emit("keypipe \(prefix)apply-failed replaceInput ignored")
                return .ignored
            case .gone:
                emit("keypipe \(prefix)apply-failed replaceInput gone")
                return .gone
            }
        case .builtin(.notify):
            desktop.notify(result)
            emit("keypipe \(prefix)apply notify \(jsonString(result))")
            return nil
        case .builtin(.none):
            emit("keypipe \(prefix)apply none \(jsonString(result))")
            return nil
        case .shell(let script):
            if case .failure(let failure) = shellStage(script, result, env, prefix: prefix, stage: "output-shell") {
                return failure
            }
            return nil
        }
    }

    private func notify(_ text: String) {
        desktop.notify(text)
        emit("keypipe apply notify \(jsonString(text))")
    }
}
