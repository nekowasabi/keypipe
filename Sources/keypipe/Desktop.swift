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
    /// Whether two handles from two snapshots are the same element. A handle is a fresh token each
    /// time, so tokens alone cannot say it.
    func sameField(_ a: Field, _ b: Field) -> Bool
    /// Shows that a matched fire is running, next to the field's caret when it can be found.
    func showBusy(near field: Field?)
    func hideBusy()
    /// Shows one finished fire's pill. Only the live daemon draws; the default is a no-op.
    func showFired(_ event: FiredEvent)
}

/// Whether a finished fire earned its pill.
enum FiredStatus: String { case ok, failed, started }

/// One finished fire worth a pill: the full pill text, the outcome, and the raw icon string.
struct FiredEvent: Equatable {
    var trigger: Trigger
    var label: String
    var status: FiredStatus
    /// The failed stage's token (transform, output, spawn). nil unless the fire failed.
    var stage: String?
    /// The rule's raw icon string. nil draws the status glyph only.
    var icon: String?
}

extension Desktop {
    /// A desktop with no live readers (the --line bridge from zsh or voice, a background job)
    /// has no such fact: a rule that needs one does not hold, and the next rule may fire.
    /// Why: on the voice path the target app is restored only after keypipe returns, so a
    /// live read would describe some other window.
    func fact(_ name: FactName) -> FactRead { .absent }

    func typeText(_ text: String) -> Bool { false }

    func sameField(_ a: Field, _ b: Field) -> Bool { a == b }

    /// Why: only the live daemon has a screen to draw on; --line and jobs have no caret.
    func showBusy(near field: Field?) {}
    func hideBusy() {}

    /// Why: only the live daemon has a screen to draw on; --line and jobs have no pill.
    func showFired(_ event: FiredEvent) {}
}
