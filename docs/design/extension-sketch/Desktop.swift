// keypipe/Sources/keypipe/Desktop.swift (changed once, in PR2; once more in PR3)
//
// Today's five methods stay exactly as they are: snapshot / backspace / text / setText /
// notify. Erase and readback (performErase / performWrite in Engine.swift) keep calling
// text(_:) repeatedly, so FakeDesktop's per-read quirks (backspacePerRead, keysPerRead,
// writePerRead: verify-keypipe-rules R4c/R4e/R4f) keep working. Two methods are added,
// both with default implementations, so the three implementations change only where they
// have something to say.

protocol Desktop {
    func snapshot() -> Snapshot
    func backspace(_ count: Int)
    func text(_ field: Field) -> String?
    func setText(_ field: Field, _ text: String) -> Bool
    func notify(_ text: String)

    /// PR2. One condition fact that is not in the Snapshot. Default: .unreadable("not available").
    func fact(_ name: FactName) -> FactRead
    /// PR3 (typeText). Default: false = this desktop cannot type (-> Failure.unsupported).
    func typeText(_ text: String) -> Bool
}

// MacDesktop:  fact -> name.readMac(front) with the MacFront resolved by snapshot();
//              typeText -> CGEvent keyboardSetUnicodeString, tagged with keypipeEventTag.
//              snapshot() additionally reports `secure` (AXSubrole == AXSecureTextField) for the M7 gate.
//
// FakeDesktop: the context JSON gains one optional object `facts`, keys validated against
//              FactName.allCases (unknown name -> same error style as config):
//                {"app":"com.google.Chrome","focusIsTextField":true,"fieldText":"",
//                 "facts":{"url":"https://github.com/a/b"},"secure":false}
//              A fact absent from `facts` reads as .unreadable (so tests can cover the stop path).
//              `reads: [FactName]` records every fact read, so a test can assert a slow fact
//              was never fetched. init gains `facts: [FactName: String] = [:]`.
//              Existing keys and all timing knobs are untouched.
//
// LineDesktop: defaults only. Decision (voice): the --line path never reads live facts, so a
//              rule with `when.url` does not match from zsh or voice. typeText stays
//              unsupported there (decision a).

/// Snapshot gains one eager, cheap field for the secure gate (M7).
struct Snapshot: Equatable {
    var app: String? = nil
    var focus: Focus
    var field: Field? = nil
    var secure: Bool = false   // PR2: AXSecureTextField in front; keypipe reads and writes nothing
}
