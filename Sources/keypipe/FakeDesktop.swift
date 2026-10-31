import Foundation

final class FakeDesktop: Desktop {
    private struct Context: Decodable {
        var app: String?
        var focusIsTextField: Bool
        var fieldText: String
        var composing: Bool?
        var ignoresBackspace: Bool?
    }

    private let app: String?
    private let focus: Focus
    private let ignoresBackspace: Bool
    private(set) var fieldText: String
    private(set) var notifications: [String] = []

    init(app: String? = nil, focus: Focus = .nothing, fieldText: String = "", ignoresBackspace: Bool = false) {
        self.app = app
        self.focus = focus
        self.fieldText = fieldText
        self.ignoresBackspace = ignoresBackspace
    }

    convenience init(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let context = try JSONDecoder().decode(Context.self, from: data)
        if context.composing == true && !context.focusIsTextField {
            throw ConfigError.invalid("composing requires focusIsTextField")
        }
        self.init(
            app: context.app,
            focus: context.composing == true ? .composing : context.focusIsTextField ? .text : .nothing,
            fieldText: context.fieldText,
            ignoresBackspace: context.ignoresBackspace ?? false)
    }

    func key(_ character: Character) { fieldText.append(character) }

    func snapshot() -> Snapshot {
        Snapshot(app: app, focus: focus, field: focus == .text ? Field(token: 0) : nil)
    }

    func backspace(_ count: Int) {
        if !ignoresBackspace { fieldText.removeLast(min(count, fieldText.count)) }
    }

    func text(_ field: Field) -> String? {
        field.token == 0 && focus == .text ? fieldText : nil
    }

    func setText(_ field: Field, _ text: String) -> Bool {
        guard field.token == 0 && focus == .text else { return false }
        fieldText = text
        return true
    }

    func notify(_ text: String) { notifications.append(text) }
}
