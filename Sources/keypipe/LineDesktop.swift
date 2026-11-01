/// One text field held in memory: the zsh line for `--line`, or no field at all for a
/// background job. Notifications are real, since nobody reads the bridge's stderr.
final class LineDesktop: Desktop {
    private let app: String?
    private(set) var line: String?

    /// line includes the trigger, so the engine's erase strips it as it would in an editor.
    init(app: String?, line: String?) {
        self.app = app
        self.line = line
    }

    func snapshot() -> Snapshot {
        Snapshot(
            app: app, focus: line == nil ? .nothing : .text,
            field: line == nil ? nil : Field(token: 0))
    }

    func backspace(_ count: Int) { line = line.map { String($0.dropLast(count)) } }

    func text(_ field: Field) -> String? { line }

    func setText(_ field: Field, _ text: String) -> Bool {
        guard line != nil else { return false }
        line = text
        return true
    }

    func notify(_ text: String) { notifyUser(text) }
}
