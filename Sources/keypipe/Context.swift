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

/// The rule's focus requirement, then its fact conditions in cost order. A terminal pane is never a
/// field, so there only a rule that reads none (focus any) can match; which triggers may fire in a
/// terminal at all is the engine's terminal gate.
func evaluate(_ when: When, _ sheet: FactSheet) -> Conditions.Verdict {
    switch sheet.snapshot.focus {
    case .composing: return .noMatch
    case .terminal, .nothing: guard when.focus == .any else { return .noMatch }
    case .text: break
    }
    return when.conditions.evaluate(sheet)
}
