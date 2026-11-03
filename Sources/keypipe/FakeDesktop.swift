import Foundation

final class FakeDesktop: Desktop {
    private struct Context: Decodable {
        var app: String?
        var focusIsTextField: Bool
        var fieldText: String
        var composing: Bool?
        var ignoresBackspace: Bool?
        var backspacePerRead: Bool?
        var keysPerRead: Bool?
        var ignoresWrite: Bool?
        var fieldGoneAfter: String?
        var writePerRead: Bool?
        var ownsPty: Bool?
        var secure: Bool?
        /// Condition facts by name; keys are checked against FactName.
        var facts: [String: String]?
        /// Facts that exist but cannot be read, with the reason.
        var unreadableFacts: [String: String]?
        /// The front app reported after the first slow fact read (an app switch mid-read).
        var appAfterSlowRead: String?
    }

    private let app: String?
    private let focus: Focus
    private let ignoresBackspace: Bool
    private let backspacePerRead: Bool
    private let keysPerRead: Bool
    private let ignoresWrite: Bool
    private let goneAfterErase: Bool
    private let writePerRead: Bool
    private var pendingWrite: String?
    private var erased = false
    private var gone = false
    private var pendingBackspaces = 0
    private var pendingKeys: [Character] = []
    private(set) var fieldText: String
    private(set) var notifications: [String] = []
    /// showBusy and hideBusy calls in order: true shown, false hidden.
    private(set) var busy: [Bool] = []
    /// showFired calls in order, so a test can demand exactly one pill per finished fire.
    private(set) var fired: [FiredEvent] = []
    /// spin, unspin and pill in the one order the engine posted them; the HudFlow model in
    /// .claude/skills/verify-keypipe-hud-flow assumes exactly this per-fire order.
    private(set) var windows: [String] = []
    private let secure: Bool
    private let facts: [FactName: FactRead]
    private let appAfterSlowRead: String?
    /// Every condition fact read, in order, so a test can assert a slow fact was never fetched.
    private(set) var reads: [FactName] = []

    /// backspacePerRead delivers one queued Backspace per text() read, like an app
    /// that processes key events between keypipe's polls. keysPerRead does the same
    /// for typed keys, like the tap seeing a key before the app has appended it.
    /// ignoresWrite accepts setText but keeps the old text (Electron-style).
    /// goneAfterErase makes the first write after the erase fail and every
    /// later read return nil, like a window closed during a slow transform.
    /// writePerRead applies setText on the read after the next one, like
    /// Chromium landing an AXValue write a few milliseconds later.
    init(
        app: String? = nil, focus: Focus = .nothing, fieldText: String = "",
        ignoresBackspace: Bool = false, backspacePerRead: Bool = false, keysPerRead: Bool = false,
        ignoresWrite: Bool = false, goneAfterErase: Bool = false, writePerRead: Bool = false,
        secure: Bool = false, facts: [FactName: FactRead] = [:], appAfterSlowRead: String? = nil
    ) {
        self.app = app
        self.secure = secure
        self.facts = facts
        self.appAfterSlowRead = appAfterSlowRead
        self.focus = focus
        self.fieldText = fieldText
        self.ignoresBackspace = ignoresBackspace
        self.backspacePerRead = backspacePerRead
        self.keysPerRead = keysPerRead
        self.ignoresWrite = ignoresWrite
        self.goneAfterErase = goneAfterErase
        self.writePerRead = writePerRead
    }

    convenience init(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let context = try JSONDecoder().decode(Context.self, from: data)
        if context.composing == true && !context.focusIsTextField {
            throw ConfigError.invalid("composing requires focusIsTextField")
        }
        if let after = context.fieldGoneAfter, after != "erase" {
            throw ConfigError.invalid("fieldGoneAfter must be erase")
        }
        var facts: [FactName: FactRead] = [:]
        for (key, value) in context.facts ?? [:] {
            guard let name = FactName(rawValue: key), name != .app else {
                throw ConfigError.invalid("unknown fact \(key)")
            }
            facts[name] = .value(value)
        }
        for (key, reason) in context.unreadableFacts ?? [:] {
            guard let name = FactName(rawValue: key), name != .app else {
                throw ConfigError.invalid("unknown fact \(key)")
            }
            facts[name] = .unreadable(reason)
        }
        self.init(
            app: context.app,
            focus: context.ownsPty == true
                ? .terminal
                : context.composing == true
                    ? .composing : context.focusIsTextField ? .text : .nothing,
            fieldText: context.fieldText,
            ignoresBackspace: context.ignoresBackspace ?? false,
            backspacePerRead: context.backspacePerRead ?? false,
            keysPerRead: context.keysPerRead ?? false,
            ignoresWrite: context.ignoresWrite ?? false,
            goneAfterErase: context.fieldGoneAfter == "erase",
            writePerRead: context.writePerRead ?? false,
            secure: context.secure ?? false,
            facts: facts,
            appAfterSlowRead: context.appAfterSlowRead)
    }

    func key(_ character: Character) {
        if keysPerRead && focus == .text {
            pendingKeys.append(character)
        } else {
            fieldText.append(character)
        }
    }

    func snapshot() -> Snapshot {
        let slowRead = reads.contains { $0.cost == .slow }
        return Snapshot(
            app: slowRead ? (appAfterSlowRead ?? app) : app, focus: focus,
            field: focus == .text ? Field(token: 0) : nil, secure: secure)
    }

    /// Same contract as MacDesktop: a caret exists in a text field (the text lands at its end) or a
    /// terminal (typed into the pane, not modelled), never in a password field or with nothing focused.
    func typeText(_ text: String) -> Bool {
        guard !secure, !gone, focus == .text || focus == .terminal else { return false }
        if focus == .text { fieldText.append(text) }
        return true
    }

    func fact(_ name: FactName) -> FactRead {
        reads.append(name)
        return facts[name] ?? .absent
    }

    func backspace(_ count: Int) {
        erased = true
        if ignoresBackspace { return }
        if backspacePerRead {
            pendingBackspaces += count
        } else {
            fieldText.removeLast(min(count, fieldText.count))
        }
    }

    func text(_ field: Field) -> String? {
        guard field.token == 0 && focus == .text && !gone else { return nil }
        defer {
            if let pending = pendingWrite {
                fieldText = pending
                pendingWrite = nil
            }
        }
        if !pendingKeys.isEmpty { fieldText.append(pendingKeys.removeFirst()) }
        if pendingBackspaces > 0 {
            pendingBackspaces -= 1
            if !fieldText.isEmpty { fieldText.removeLast() }
        }
        return fieldText
    }

    func setText(_ field: Field, _ text: String) -> Bool {
        guard field.token == 0 && focus == .text && !gone else { return false }
        if goneAfterErase && erased {
            gone = true
            return false
        }
        if ignoresWrite { return true }
        if writePerRead { pendingWrite = text } else { fieldText = text }
        return true
    }

    func notify(_ text: String) { notifications.append(text) }

    func showBusy(near field: Field?) {
        busy.append(true)
        windows.append("spin")
    }
    func hideBusy() {
        busy.append(false)
        windows.append("unspin")
    }

    func showFired(_ event: FiredEvent) {
        fired.append(event)
        windows.append("pill")
    }
}
