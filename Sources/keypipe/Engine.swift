import Foundation

func jsonString(_ text: String) -> String {
    let data = try! JSONSerialization.data(
        withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

/// Why a stage failed. The token is both the transcript word and KEYPIPE_FAILURE.
enum Failure: Error, Hashable {
    /// `reason` is the last stderr line, or "".
    case exit(Int32, reason: String)
    case timeout, empty, ignored, gone
    /// The desktop cannot do it at all (typeText through --line: there is no caret).
    case unsupported

    var token: String {
        switch self {
        case .exit(let status, _): return "exit \(status)"
        case .timeout: return "timeout"
        case .empty: return "empty"
        case .ignored: return "ignored"
        case .gone: return "gone"
        case .unsupported: return "unsupported"
        }
    }

    /// The token plus the shell's own reason, for the notification.
    /// Why: a background job's stderr reaches no one else.
    var message: String {
        guard case .exit(_, let reason) = self, !reason.isEmpty else { return token }
        return "\(token): \(reason.prefix(200))"
    }
}

/// A shell stage, named as the transcript names it.
enum ShellStage: String, CustomStringConvertible {
    case transform
    case outputShell = "output-shell"
    var description: String { rawValue }
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
func performErase(_ field: Field, trigger: String, _ desktop: Desktop, emit: (String) -> Void)
    -> String?
{
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

/// The pill and transcript text for a finished fire. The label wins, then the name; otherwise the
/// primary shell script; otherwise the builtin sink name. Every run of whitespace collapses
/// to one space before the label text is capped at 40 graphemes.
/// Never stdout or field text.
func firedLabel(trigger: Trigger, rule: Rule) -> String {
    let raw: String
    if let label = rule.label ?? rule.name {
        raw = label
    } else {
        switch rule.output.primary {
        case .shell(let shell): raw = shell.script
        case .builtin(let sink): raw = sink.rawValue
        }
    }
    let text = String(raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(40))
    return "\(trigger) → \(text.trimmingCharacters(in: .whitespaces))"
}

/// A background fire handed to a detached job: the rule by config index, the read input,
/// and the environment the shells see.
struct Job: Codable, Equatable {
    var rule: Int
    var input: String
    var environment: [String: String]
}

/// What one fire did. The single source for --line's exit code, --smoke-feed's hit count,
/// --report's JSON and the pill.
enum FireResult: Equatable {
    /// A gate stopped the fire before anything was erased or run. The word is the transcript
    /// token: terminal, composing, secure, deny (before any rule is looked at), front-changed (the
    /// front moved during a slow read, after the rule was chosen).
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

    /// One per case, so a test can demand a golden --report line for every kind of outcome.
    enum Kind: CaseIterable {
        case blocked, noMatch, unreadable, noInput, replaced, delivered, started, failed
    }

    var kind: Kind {
        switch self {
        case .blocked: return .blocked
        case .noMatch: return .noMatch
        case .unreadable: return .unreadable
        case .noInput: return .noInput
        case .replaced: return .replaced
        case .delivered: return .delivered
        case .started: return .started
        case .failed: return .failed
        }
    }

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

    init(
        config: KeypipeConfig, desktop: Desktop,
        shell: @escaping (String, String, [String: String], TimeInterval) -> ShellOutcome,
        emit: @escaping (String) -> Void,
        background: @escaping (Job) -> Bool = { _ in false }
    ) {
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
        let matching = config.rules.indices.filter { config.rules[$0].trigger == trigger }
        return fire(trigger, candidates: matching, input: nil)
    }

    /// `--rule`: only this rule, through the same gates, with the caller's input whatever its focus.
    @discardableResult
    mutating func fire(rule index: Int, input: String) -> FireResult {
        fire(config.rules[index].trigger, candidates: [index], input: input)
    }

    private mutating func fire(_ trigger: Trigger, candidates: [Int], input: String?)
        -> FireResult
    {
        let snapshot = desktop.snapshot()
        // Gates, before any rule and before any field read.
        var candidates = candidates
        if snapshot.focus == .terminal {
            // Why: a terminal's AX field is the whole pane. A text trigger there belongs to the
            // zsh widget; only a hotkey rule that reads no field may still run (empty input).
            candidates =
                trigger.isHotkey ? candidates.filter { config.rules[$0].when.focus == .any } : []
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
        for entry in config.deny {
            switch entry.evaluate(sheet) {
            case .noMatch: continue
            case .match:
                emit("keypipe deny \(trigger)")
                return .blocked("deny")
            case .unreadable(let fact, let reason):
                // Fail safe: an exclusion that cannot be checked stops the fire, and says why, so a
                // missing Automation permission is not a silent dead trigger.
                emit("keypipe deny-unreadable \(trigger) \(fact.rawValue)")
                notify("\(trigger): deny cannot read \(fact.rawValue): \(reason)")
                return .unreadable(fact: fact.rawValue, reason: reason)
            }
        }
        var chosen: Int?
        for candidate in candidates {
            let verdict = evaluate(config.rules[candidate].when, sheet)
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
        let rule = config.rules[index]
        // Why: a slow read can take up to a second. Backspaces go to whatever has focus now, so
        // the gates are taken again: another app, another kind of focus (a password field in the
        // same browser), or a field that no longer ends with the trigger (the user typed on)
        // means nothing is erased or run.
        if sheet.readSlow {
            // Another field of the same app counts as moved: the old one still ends with the
            // trigger, but the Backspaces would land in the new one.
            var moved = !snapshot.isStillFront(desktop.snapshot(), desktop)
            // Why waitForTrigger and not one read: a trigger key the tap saw may still be on its way
            // into the field, exactly as on the fast path (R4e).
            if !moved, case .text(let text) = trigger, snapshot.focus == .text,
                let field = snapshot.field
            {
                moved = !(waitForTrigger(field, text, desktop)?.hasSuffix(text) ?? false)
                // The wait can take 0.1 s more: look at the focus once more after it.
                if !moved { moved = !snapshot.isStillFront(desktop.snapshot(), desktop) }
            }
            if moved {
                emit("keypipe front-changed \(trigger)")
                return .blocked("front-changed")
            }
        }
        hits += 1
        emit("keypipe matched \(trigger) rule \(index)")
        // Why: a transform can take seconds with no visible change; the field is read before
        // the erase so the spinner sits where the trigger was typed.
        desktop.showBusy(near: snapshot.field)
        let result = runAfterBusy(
            rule: rule, index: index, trigger: trigger, snapshot: snapshot, suppliedInput: input)
        desktop.hideBusy()
        showFiredIfNeeded(result, trigger: trigger, rule: rule)
        return result
    }

    /// Everything after the spinner is up: erase, input, background spawn or the sync stages.
    /// The caller hides the spinner and decides the pill, so every path here leaves both to it.
    private func runAfterBusy(
        rule: Rule, index: Int, trigger: Trigger, snapshot: Snapshot, suppliedInput: String?
    ) -> FireResult {
        let input: String
        switch (trigger, rule.when.focus, suppliedInput) {
        case (_, _, .some(let supplied)):
            // Why: a rule called by name was never typed, so there is nothing to erase.
            emit("keypipe erase 0")
            input = supplied
        case (.text(let text), .textField, nil):
            guard let field = snapshot.field,
                let erased = performErase(field, trigger: text, desktop, emit: emit)
            else { return .noInput(rule: index) }
            input = erased
        case (.hotkey, .textField, nil):
            emit("keypipe erase 0")
            guard let field = snapshot.field, let current = desktop.text(field) else {
                return .noInput(rule: index)
            }
            input = current
        case (.text(let text), .any, nil):
            let count = snapshot.focus == .text ? text.count : 0
            if count > 0, let field = snapshot.field {
                _ = waitForTrigger(field, text, desktop)
                desktop.backspace(count)
            }
            emit("keypipe erase \(count)")
            input = ""
        case (.hotkey, .any, nil):
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
        return run(rule, index, input, environment, snapshot)
    }

    /// One pill per finished fire that earned it, then one transcript line for it. Fires that
    /// never reached the spinner (gates, no match, unreadable facts) and a vanished field
    /// (noInput) report nothing: there is no finished work to show.
    private func showFiredIfNeeded(_ result: FireResult, trigger: Trigger, rule: Rule) {
        guard config.hud else { return }
        let status: FiredStatus
        switch result {
        case .replaced, .delivered: status = .ok
        case .started: status = .started
        case .failed: status = .failed
        case .blocked, .noMatch, .unreadable, .noInput: return
        }
        var stage: String? = nil
        if case .failed(_, let failedStage, _) = result { stage = failedStage.rawValue }
        let event = FiredEvent(
            trigger: trigger, label: firedLabel(trigger: trigger, rule: rule), status: status,
            stage: stage, icon: rule.icon)
        desktop.showFired(event)
        emit(
            "keypipe hud \(trigger) \(status.rawValue) \(jsonString(event.label)) \(rule.icon.map(jsonString) ?? "none")"
        )
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

    private func run(
        _ rule: Rule, _ index: Int, _ input: String, _ environment: [String: String],
        _ origin: Snapshot?
    ) -> FireResult {
        // Why: a rule called by name from voice-switch was never typed, so its trigger means nothing to the user.
        let title = rule.label ?? rule.name ?? "\(rule.trigger)"
        var result = input
        if let transform = rule.transform {
            switch runTransform(transform, input, environment) {
            case .success(let output): result = output
            case .failure(let failure):
                notify("\(title) transform failed: \(failure.message)")
                return .failed(rule: index, stage: .transform, failure: failure.token)
            }
        }
        func success(_ output: Output, viaFallback: Bool) -> FireResult {
            output.writesField
                ? .replaced(rule: index, text: result, viaFallback: viaFallback)
                : .delivered(rule: index, viaFallback: viaFallback)
        }
        guard let failure = apply(rule.output.primary, result, environment, origin, prefix: "")
        else {
            return success(rule.output.primary, viaFallback: false)
        }
        guard let fallback = rule.output.onFail else {
            // Why: without a fallback the text must not be lost, and a sync shell's own
            // failure is already visible in the transcript; nobody watches a job's.
            if case .builtin = rule.output.primary {
                notify(result)
            } else if rule.output.primary.isBackground {
                notify("\(title) output failed: \(failure.message)")
            }
            return .failed(rule: index, stage: .output, failure: failure.token)
        }
        var environment2 = environment
        environment2["KEYPIPE_FAILURE"] = failure.token
        if let second = apply(fallback, result, environment2, origin, prefix: "fallback ") {
            notify("\(title) output failed: \(second.message)")
            return .failed(rule: index, stage: .output, failure: second.token)
        }
        return success(fallback, viaFallback: true)
    }

    /// Primary once, then onFail once with the same input and KEYPIPE_FAILURE set.
    private func runTransform(
        _ transform: Guarded<String>, _ input: String, _ env: [String: String]
    )
        -> Result<String, Failure>
    {
        switch shellStage(transform.primary, input, env, prefix: "", stage: .transform) {
        case .success(let output): return .success(output)
        case .failure(let failure):
            guard let fallback = transform.onFail else { return .failure(failure) }
            var env = env
            env["KEYPIPE_FAILURE"] = failure.token
            return shellStage(fallback, input, env, prefix: "fallback ", stage: .transform)
        }
    }

    private func shellStage(
        _ script: String, _ input: String, _ env: [String: String], prefix: String,
        stage: ShellStage
    )
        -> Result<String, Failure>
    {
        switch shell(script, input, env, config.shellTimeout) {
        case .exited(let status, let output, let errors):
            emit("keypipe \(prefix)\(stage) exit \(status)")
            guard status == 0 else {
                let reason =
                    errors.split(whereSeparator: \.isNewline).last.map {
                        $0.trimmingCharacters(in: .whitespaces)
                    } ?? ""
                if !reason.isEmpty {
                    emit("keypipe \(prefix)\(stage) stderr \(jsonString(reason))")
                }
                return .failure(.exit(status, reason: reason))
            }
            if stage == .transform && output.isEmpty {
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

    /// nil on success. A sink that cannot fail (spec.failures empty) always returns nil.
    private func apply(
        _ output: Output, _ result: String, _ env: [String: String], _ origin: Snapshot?,
        prefix: String
    )
        -> Failure?
    {
        switch output {
        case .builtin(let sink):
            if let failure = sink.perform(result, origin: origin, desktop) {
                emit("keypipe \(prefix)apply-failed \(sink.rawValue) \(failure.token)")
                return failure
            }
            emit("keypipe \(prefix)apply \(sink.rawValue) \(jsonString(result))")
            return nil
        case .shell(let shell):
            if case .failure(let failure) = shellStage(
                shell.script, result, env, prefix: prefix, stage: .outputShell)
            {
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
