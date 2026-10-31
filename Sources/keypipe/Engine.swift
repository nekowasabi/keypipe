import Foundation

func jsonString(_ text: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

func performErase(_ field: Field, trigger: String, _ desktop: Desktop, emit: (String) -> Void) -> String? {
    guard let before = desktop.text(field) else { return nil }
    desktop.backspace(trigger.count)
    emit("keypipe erase \(trigger.count)")
    let deadline = ProcessInfo.processInfo.systemUptime + 0.2
    var after = desktop.text(field)
    // Why: Wait for delivered Backspaces before deciding to rewrite; late delivery could erase user text twice.
    while after == before && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.005)
        after = desktop.text(field)
    }
    guard let current = after else { return nil }
    if current == before && current.hasSuffix(trigger) {
        let erased = String(current.dropLast(trigger.count))
        guard desktop.setText(field, erased) else { return nil }
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
    private(set) var hits = 0

    init(config: KeypipeConfig, desktop: Desktop,
         shell: @escaping (String, String, [String: String], TimeInterval) -> ShellOutcome,
         emit: @escaping (String) -> Void) {
        self.config = config
        self.desktop = desktop
        self.shell = shell
        self.emit = emit
        self.matcher = TriggerMatcher(triggers: config.rules.map { $0.trigger })
    }

    mutating func key(_ character: Character) {
        guard let trigger = matcher.feed(character) else { return }
        matcher.reset()
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
        if rule.when.focus == .textField {
            guard let field = snapshot.field,
                  let erased = performErase(field, trigger: trigger, desktop, emit: emit) else { return }
            input = erased
        } else {
            let count = snapshot.focus == .text ? trigger.count : 0
            if count > 0 { desktop.backspace(count) }
            emit("keypipe erase \(count)")
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
