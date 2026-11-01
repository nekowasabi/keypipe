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
    }

    private let app: String?
    private let focus: Focus
    private let ignoresBackspace: Bool
    private let backspacePerRead: Bool
    private let keysPerRead: Bool
    private let ignoresWrite: Bool
    private let goneAfterErase: Bool
    private var erased = false
    private var gone = false
    private var pendingBackspaces = 0
    private var pendingKeys: [Character] = []
    private(set) var fieldText: String
    private(set) var notifications: [String] = []

    /// backspacePerRead delivers one queued Backspace per text() read, like an app
    /// that processes key events between keypipe's polls. keysPerRead does the same
    /// for typed keys, like the tap seeing a key before the app has appended it.
    /// ignoresWrite accepts setText but keeps the old text (Electron-style).
    /// goneAfterErase makes the first write after the erase fail and every
    /// later read return nil, like a window closed during a slow transform.
    init(app: String? = nil, focus: Focus = .nothing, fieldText: String = "",
         ignoresBackspace: Bool = false, backspacePerRead: Bool = false, keysPerRead: Bool = false,
         ignoresWrite: Bool = false, goneAfterErase: Bool = false) {
        self.app = app
        self.focus = focus
        self.fieldText = fieldText
        self.ignoresBackspace = ignoresBackspace
        self.backspacePerRead = backspacePerRead
        self.keysPerRead = keysPerRead
        self.ignoresWrite = ignoresWrite
        self.goneAfterErase = goneAfterErase
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
        self.init(
            app: context.app,
            focus: context.composing == true ? .composing : context.focusIsTextField ? .text : .nothing,
            fieldText: context.fieldText,
            ignoresBackspace: context.ignoresBackspace ?? false,
            backspacePerRead: context.backspacePerRead ?? false,
            keysPerRead: context.keysPerRead ?? false,
            ignoresWrite: context.ignoresWrite ?? false,
            goneAfterErase: context.fieldGoneAfter == "erase")
    }

    func key(_ character: Character) {
        if keysPerRead && focus == .text { pendingKeys.append(character) } else { fieldText.append(character) }
    }

    func snapshot() -> Snapshot {
        Snapshot(app: app, focus: focus, field: focus == .text ? Field(token: 0) : nil)
    }

    func backspace(_ count: Int) {
        erased = true
        if ignoresBackspace { return }
        if backspacePerRead { pendingBackspaces += count } else { fieldText.removeLast(min(count, fieldText.count)) }
    }

    func text(_ field: Field) -> String? {
        guard field.token == 0 && focus == .text && !gone else { return nil }
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
        if !ignoresWrite { fieldText = text }
        return true
    }

    func notify(_ text: String) { notifications.append(text) }
}
