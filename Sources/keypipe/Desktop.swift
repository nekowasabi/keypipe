protocol Desktop {
    func snapshot() -> Snapshot
    func backspace(_ count: Int)
    func text(_ field: Field) -> String?
    func setText(_ field: Field, _ text: String) -> Bool
    func notify(_ text: String)
}
