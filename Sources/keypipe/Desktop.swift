protocol Desktop {
    func snapshot() -> Snapshot
    func backspace(_ count: Int)
    func text(_ field: Field) -> String?
    func setText(_ field: Field, _ text: String) -> Bool
    func notify(_ text: String)
    /// One condition fact that is not in the snapshot.
    func fact(_ name: FactName) -> FactRead
    /// Types text at the caret. false: this desktop cannot type (the --line bridge, a job).
    func typeText(_ text: String) -> Bool
}

extension Desktop {
    /// A desktop with no live readers (the --line bridge from zsh or voice, a background job)
    /// has no such fact: a rule that needs one does not hold, and the next rule may fire.
    /// Why: on the voice path the target app is restored only after keypipe returns, so a
    /// live read would describe some other window.
    func fact(_ name: FactName) -> FactRead { .absent }

    func typeText(_ text: String) -> Bool { false }
}
