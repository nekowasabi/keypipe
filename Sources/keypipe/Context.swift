/// terminal: the front app holds a pty master; its AX field is the whole pane, so no rule that
/// reads a field fires there.
enum Focus: Equatable { case nothing, text, composing, terminal }

struct Field: Equatable { var token: Int }

/// What the desktop reports eagerly for every fire: cheap, and enough for every gate.
struct Snapshot: Equatable {
    var app: String? = nil
    var focus: Focus
    var field: Field? = nil
    /// The focused element is a password field (AXSecureTextField). keypipe reads nothing there.
    var secure = false
}

/// The rule's focus requirement, then its fact conditions in cost order.
func evaluate(_ when: When, _ sheet: FactSheet) -> Conditions.Verdict {
    guard sheet.snapshot.focus != .composing && sheet.snapshot.focus != .terminal else {
        return .noMatch
    }
    guard when.focus == .any || sheet.snapshot.focus == .text else { return .noMatch }
    return when.conditions.evaluate(sheet)
}
