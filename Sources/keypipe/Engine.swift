import Foundation

func jsonString(_ text: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
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

func performErase(_ field: Field, trigger: String, _ desktop: Desktop, emit: (String) -> Void) -> String? {
    guard let before = waitForTrigger(field, trigger, desktop) else { return nil }
    desktop.backspace(trigger.count)
    emit("keypipe erase \(trigger.count)")
    guard before.hasSuffix(trigger) else { return desktop.text(field) }
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
    if current == before {
        guard desktop.setText(field, expected) else { return nil }
        emit("keypipe erase-rewrite")
        return desktop.text(field)
    }
    return current
}

func performWrite(_ field: Field, _ text: String, _ desktop: Desktop) -> Bool {
    desktop.setText(field, text) && desktop.text(field) == text
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
            switch shell(transform.primary, input, environment, 30) {
            case .exited(let status, let output):
                emit("keypipe transform exit \(status)")
                guard status == 0 else {
                    notify("\(trigger) transform failed: exit \(status)")
                    return
                }
                // Why: an empty result would wipe the field through replaceInput.
                guard !output.isEmpty else {
                    emit("keypipe transform empty")
                    notify("\(trigger) transform failed: empty")
                    return
                }
                result = output
            case .timedOut(let seconds):
                emit("keypipe transform timeout \(seconds)")
                notify("\(trigger) transform failed: timeout \(seconds)")
                return
            }
        }
        switch rule.output.primary {
        case .builtin(.replaceInput):
            if let field = snapshot.field, performWrite(field, result, desktop) {
                emit("keypipe apply replaceInput \(jsonString(result))")
            } else {
                notify(result)
            }
        case .builtin(.notify):
            notify(result)
        case .builtin(.none):
            emit("keypipe apply none \(jsonString(result))")
        case .shell(let script):
            switch shell(script, result, environment, 30) {
            case .exited(let status, _): emit("keypipe output-shell exit \(status)")
            case .timedOut(let seconds): emit("keypipe output-shell timeout \(seconds)")
            }
        }
    }

    private func notify(_ text: String) {
        desktop.notify(text)
        emit("keypipe apply notify \(jsonString(text))")
    }
}
