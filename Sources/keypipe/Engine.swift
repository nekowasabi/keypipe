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

/// Why: Chromium (and so Electron) applies an AXValue write about 12 ms after
/// accepting it; an immediate readback would call a landed write ignored.
func performWrite(_ field: Field, _ text: String, _ desktop: Desktop) -> WriteOutcome {
    guard desktop.setText(field, text) else { return .gone }
    let deadline = ProcessInfo.processInfo.systemUptime + 0.2
    while true {
        guard let readback = desktop.text(field) else { return .gone }
        if readback == text { return .written }
        if ProcessInfo.processInfo.systemUptime >= deadline { return .ignored }
        Thread.sleep(forTimeInterval: 0.005)
    }
}

/// A background fire handed to a detached job: the rule by config index, the read input,
/// and the environment the shells see.
struct Job: Codable, Equatable {
    var rule: Int
    var input: String
    var environment: [String: String]
}

/// What one fire did. The single source for --line's exit code, --smoke-feed's hit count,
/// --report's JSON and the voice-switch decision.
enum FireResult: Equatable {
    /// A gate stopped the fire before any rule was looked at. The word is the transcript
    /// token: terminal, composing, secure, deny.
    case blocked(String)
    case noMatch
    /// A condition fact could not be read. The fire stops: it does not fall through to the
    /// next rule of the same trigger, so a rule meant for one site never turns into another.
    case unreadable(fact: String, reason: String)
    /// Matched, but the field vanished before it could be read. Counts as a hit, as before.
    case noInput(rule: Int)
    /// replaceInput (primary or fallback) wrote the result.
    case replaced(rule: Int, text: String, viaFallback: Bool)
    /// Any other output succeeded.
    case delivered(rule: Int, viaFallback: Bool)
    /// Handed to a detached job that did start; its outcome lands in jobs.log.
    case started(rule: Int)
    case failed(rule: Int, stage: Stage, failure: String)

    enum Stage: String { case transform, output, spawn }

    /// "A rule matched", as --line's exit 0 and --smoke-feed's hits have always meant.
    var isHit: Bool {
        switch self {
        case .blocked, .noMatch, .unreadable: return false
        case .noInput, .replaced, .delivered, .started, .failed: return true
        }
    }
}

struct Engine {
    private let config: KeypipeConfig
    private let desktop: Desktop
    private let shell: (String, String, [String: String], TimeInterval) -> ShellOutcome
    private let emit: (String) -> Void
    /// Returns whether the detached job started, so a failed spawn is never reported as started.
    private let background: (Job) -> Bool
    private var matcher: TriggerMatcher
    private let hotkeys: Set<Hotkey>
    private(set) var hits = 0

    init(config: KeypipeConfig, desktop: Desktop,
         shell: @escaping (String, String, [String: String], TimeInterval) -> ShellOutcome,
         emit: @escaping (String) -> Void,
         background: @escaping (Job) -> Bool = { _ in false }) {
        self.config = config
        self.background = background
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

    @discardableResult
    mutating func fire(_ trigger: Trigger) -> FireResult {
        let snapshot = desktop.snapshot()
        // Gates, before any rule and before any field read.
        var candidates = config.rules.indices.filter { config.rules[$0].trigger == trigger }
        if snapshot.focus == .terminal {
            // Why: a terminal's AX field is the whole pane. A text trigger there belongs to the
            // zsh widget; only a hotkey rule that reads no field may still run (empty input).
            candidates = trigger.isHotkey ? candidates.filter { config.rules[$0].when.focus == .any } : []
            guard !candidates.isEmpty else {
                emit("keypipe terminal \(trigger)")
                return .blocked("terminal")
            }
        }
        guard snapshot.focus != .composing else {
            emit("keypipe composing \(trigger)")
            return .blocked("composing")
        }
        guard !snapshot.secure else {
            emit("keypipe secure \(trigger)")
            return .blocked("secure")
        }
        let sheet = FactSheet(snapshot, desktop: desktop)
        for entry in config.deny where entry.evaluate(sheet) != .noMatch {
            emit("keypipe deny \(trigger)")
            return .blocked("deny")
        }
        var chosen: Int?
        for candidate in candidates {
            // In a terminal the filter above already kept only focus-any rules; evaluate() itself
            // treats a terminal as matching nothing, which is right for every other caller.
            let when = config.rules[candidate].when
            let verdict = snapshot.focus == .terminal ? when.conditions.evaluate(sheet) : evaluate(when, sheet)
            if verdict == .noMatch { continue }
            if case .unreadable(let fact, let reason) = verdict {
                // Why: a rule meant for one site must not turn into the next rule of the trigger.
                emit("keypipe unreadable \(trigger) \(fact.rawValue)")
                notify("\(trigger): cannot read \(fact.rawValue): \(reason)")
                return .unreadable(fact: fact.rawValue, reason: reason)
            }
            chosen = candidate
            break
        }
        guard let index = chosen else {
            emit("keypipe nomatch \(trigger)")
            return .noMatch
        }
        // Why: a slow read can take up to a second. If the user switched apps meanwhile, the
        // Backspaces would land in the new front app, so nothing is erased or run.
        if sheet.readSlow && desktop.snapshot().app != snapshot.app {
            emit("keypipe front-changed \(trigger)")
            return .noMatch
        }
        let rule = config.rules[index]
        hits += 1
        emit("keypipe matched \(trigger) rule \(index)")
        let input: String
        switch (trigger, rule.when.focus) {
        case (.text(let text), .textField):
            guard let field = snapshot.field,
                  let erased = performErase(field, trigger: text, desktop, emit: emit) else { return .noInput(rule: index) }
            input = erased
        case (.hotkey, .textField):
            emit("keypipe erase 0")
            guard let field = snapshot.field, let current = desktop.text(field) else { return .noInput(rule: index) }
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
        if rule.output.primary.isBackground {
            emit("keypipe background rule \(index)")
            guard background(Job(rule: index, input: input, environment: environment)) else {
                return .failed(rule: index, stage: .spawn, failure: "spawn")
            }
            return .started(rule: index)
        }
        return run(rule, index, input, environment, snapshot.field)
    }

    /// The detached half of a background fire: same stages, no field to write.
    @discardableResult
    func run(_ job: Job) -> FireResult {
        guard config.rules.indices.contains(job.rule) else {
            notify("background job: no rule \(job.rule)")
            return .noMatch
        }
        return run(config.rules[job.rule], job.rule, job.input, job.environment, nil)
    }

    private func run(_ rule: Rule, _ index: Int, _ input: String, _ environment: [String: String], _ field: Field?) -> FireResult {
        let trigger = rule.trigger
        var result = input
        if let transform = rule.transform {
            switch runTransform(transform, input, environment) {
            case .success(let output): result = output
            case .failure(let failure):
                notify("\(trigger) transform failed: \(failure.token)")
                return .failed(rule: index, stage: .transform, failure: failure.token)
            }
        }
        func success(_ output: Output, viaFallback: Bool) -> FireResult {
            output == .builtin(.replaceInput)
                ? .replaced(rule: index, text: result, viaFallback: viaFallback)
                : .delivered(rule: index, viaFallback: viaFallback)
        }
        guard let failure = apply(rule.output.primary, result, environment, field, prefix: "") else {
            return success(rule.output.primary, viaFallback: false)
        }
        guard let fallback = rule.output.onFail else {
            // Why: without a fallback the text must not be lost, and a sync shell's own
            // failure is already visible in the transcript; nobody watches a job's.
            if rule.output.primary == .builtin(.replaceInput) { notify(result) }
            else if rule.output.primary.isBackground { notify("\(trigger) output failed: \(failure.token)") }
            return .failed(rule: index, stage: .output, failure: failure.token)
        }
        var environment2 = environment
        environment2["KEYPIPE_FAILURE"] = failure.token
        if let second = apply(fallback, result, environment2, field, prefix: "fallback ") {
            notify("\(trigger) output failed: \(second.token)")
            return .failed(rule: index, stage: .output, failure: second.token)
        }
        return success(fallback, viaFallback: true)
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
        case .shell(let shell):
            if case .failure(let failure) = shellStage(shell.script, result, env, prefix: prefix, stage: "output-shell") {
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
