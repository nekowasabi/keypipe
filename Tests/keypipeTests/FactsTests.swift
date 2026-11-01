import XCTest

@testable import keypipe

/// A desktop that counts fact reads and fails the test if the field is ever read.
private final class CountingDesktop: Desktop {
    let snap: Snapshot
    let facts: [FactName: FactRead]
    private(set) var reads: [FactName] = []
    private(set) var fieldReads = 0
    init(_ snap: Snapshot, _ facts: [FactName: FactRead] = [:]) {
        self.snap = snap
        self.facts = facts
    }
    func snapshot() -> Snapshot { snap }
    func backspace(_ count: Int) {}
    func text(_ field: Field) -> String? {
        fieldReads += 1
        return ""
    }
    func setText(_ field: Field, _ text: String) -> Bool { true }
    func notify(_ text: String) {}
    func fact(_ name: FactName) -> FactRead {
        reads.append(name)
        return facts[name] ?? .absent
    }
}

final class FactsTests: XCTestCase {
    /// P4: for every list of up to three terms and every outcome of each, a fact is read only
    /// when every cheaper term matched, at most once per fire, and the verdict is decided by the
    /// first term (in cost order) that does not match.
    func testLazyReadsOverEveryTermAndOutcome() {
        // Two facts exist today: app (structural, from the snapshot) and url (slow).
        let outcomes: [FactRead] = [.value("hit"), .value("miss"), .absent, .unreadable("why")]
        let appValues: [String?] = ["hit", "miss", nil]
        for app in appValues {
            for url in outcomes {
                for shape in [[FactName.app], [.url], [.app, .url], [.url, .app], [.url, .url]] {
                    let desktop = CountingDesktop(Snapshot(app: app, focus: .text), [.url: url])
                    let sheet = FactSheet(desktop.snap, desktop: desktop)
                    let conditions = Conditions(shape.map { Term(fact: $0, globs: ["hit"]) })
                    let verdict = conditions.evaluate(sheet)
                    // Spec, computed without Conditions: walk app terms first, then url terms.
                    var expected = Conditions.Verdict.match
                    var expectedReads = 0
                    let ordered = shape.filter { $0 == .app } + shape.filter { $0 == .url }
                    for fact in ordered {
                        let read: FactRead = fact == .app ? (app.map(FactRead.value) ?? .absent) : url
                        if fact == .url && expectedReads == 0 { expectedReads = 1 }
                        if case .value("hit") = read { continue }
                        if case .unreadable(let reason) = read { expected = .unreadable(fact, reason) } else { expected = .noMatch }
                        break
                    }
                    XCTAssertEqual(verdict, expected, "app \(String(describing: app)) url \(url) shape \(shape)")
                    XCTAssertEqual(desktop.reads.count, expectedReads, "app \(String(describing: app)) url \(url) shape \(shape)")
                    XCTAssertTrue(desktop.reads.allSatisfy { $0 == .url }, "app comes from the snapshot")
                }
            }
        }
    }

    /// P6: no gate reads the field. For every gate state, focus, and trigger kind, a blocked fire
    /// never calls text(_:).
    func testGatesNeverReadTheField() throws {
        let hotkey = try Hotkey.parse("ctrl+@")
        let snapshots: [(Snapshot, String)] = [
            (Snapshot(app: "editor", focus: .composing, field: Field(token: 0)), "composing"),
            (Snapshot(app: "term", focus: .terminal), "terminal"),
            (Snapshot(app: "editor", focus: .nothing, secure: true), "secure"),
            (Snapshot(app: "bank", focus: .text, field: Field(token: 0)), "deny"),
        ]
        for (snap, word) in snapshots {
            for focus in [When.Focus.textField, .any] {
                for trigger in [Trigger.text("@@@"), .hotkey(hotkey)] {
                    if word == "terminal" && trigger.isHotkey && focus == .any { continue }  // M18: allowed
                    let desktop = CountingDesktop(snap)
                    let rule = Rule(trigger: trigger, when: When(focus: focus), output: Guarded(primary: .shell("x")))
                    let config = KeypipeConfig(rules: [rule], deny: [Conditions([Term(fact: .app, globs: ["bank"])])])
                    var engine = Engine(config: config, desktop: desktop, shell: { _, _, _, _ in
                        XCTFail("no shell runs behind a gate")
                        return .exited(0, stdout: "")
                    }, emit: { _ in })
                    XCTAssertEqual(engine.fire(trigger), .blocked(word), "\(word) \(focus) \(trigger)")
                    XCTAssertEqual(desktop.fieldReads, 0, "\(word) \(focus) \(trigger)")
                }
            }
        }
    }

    /// M18: in a terminal a focus-any hotkey rule runs with empty input; every text trigger and
    /// every textField rule stays blocked.
    func testTerminalAllowsOnlyFocusAnyHotkeys() throws {
        let hotkey = try Hotkey.parse("ctrl+@")
        let desktop = CountingDesktop(Snapshot(app: "term", focus: .terminal))
        let rules = [Rule(trigger: .hotkey(hotkey), when: When(focus: .textField), output: Guarded(primary: .shell("no"))),
                     Rule(trigger: .hotkey(hotkey), output: Guarded(primary: .shell("yes")))]
        var ran: [String] = []
        var engine = Engine(config: KeypipeConfig(rules: rules), desktop: desktop, shell: { script, input, _, _ in
            ran.append(script)
            XCTAssertEqual(input, "")
            return .exited(0, stdout: "")
        }, emit: { _ in })
        XCTAssertEqual(engine.fire(.hotkey(hotkey)), .delivered(rule: 1, viaFallback: false))
        XCTAssertEqual(ran, ["yes"])
        XCTAssertEqual(desktop.fieldReads, 0)
    }

    /// P5: an unreadable fact stops the fire: the next rule of the same trigger does not run,
    /// nothing is erased.
    func testUnreadableStopsWithoutFallingThrough() {
        let desktop = FakeDesktop(app: "com.google.Chrome", focus: .text, fieldText: "hi",
                                  facts: [.url: .unreadable("timeout")])
        let rules = [Rule(trigger: "@@@", when: When(focus: .textField, facts: [Term(fact: .url, globs: ["*github.com*"])]),
                          output: Guarded(primary: .shell("github"))),
                     Rule(trigger: "@@@", when: When(focus: .textField), output: Guarded(primary: .shell("catchall")))]
        var lines: [String] = []
        var engine = Engine(config: KeypipeConfig(rules: rules), desktop: desktop, shell: { _, _, _, _ in
            XCTFail("nothing runs")
            return .exited(0, stdout: "")
        }, emit: { lines.append($0) })
        for c in "@@@" { desktop.key(c) }
        XCTAssertEqual(engine.fire("@@@"), .unreadable(fact: "url", reason: "timeout"))
        XCTAssertEqual(desktop.fieldText, "hi@@@", "no Backspace")
        XCTAssertEqual(desktop.notifications, ["@@@: cannot read url: timeout"])
        XCTAssertEqual(engine.hits, 0)
        XCTAssertTrue(lines.contains("keypipe unreadable @@@ url"))
    }

    func testUrlRuleMatchesOnlyItsSiteAndIsReadOnlyWhenTheAppMatches() {
        let rules = [Rule(trigger: "@@@", when: When(app: ["com.google.Chrome"], focus: .textField,
                                                    facts: [Term(fact: .url, globs: ["https://github.com/*"])]),
                          output: Guarded(primary: .shell("github"))),
                     Rule(trigger: "@@@", when: When(focus: .textField), output: Guarded(primary: .shell("catchall")))]
        func run(_ app: String, _ url: FactRead?) -> (FireResult, String?, [FactName]) {
            let desktop = FakeDesktop(app: app, focus: .text, fieldText: "x", facts: url.map { [.url: $0] } ?? [:])
            for c in "@@@" { desktop.key(c) }
            var ran: String?
            var engine = Engine(config: KeypipeConfig(rules: rules), desktop: desktop, shell: { script, _, _, _ in
                ran = script
                return .exited(0, stdout: "")
            }, emit: { _ in })
            return (engine.fire("@@@"), ran, desktop.reads)
        }
        XCTAssertEqual(run("com.google.Chrome", .value("https://github.com/a/b")).1, "github")
        XCTAssertEqual(run("com.google.Chrome", .value("https://example.com/")).1, "catchall")
        XCTAssertEqual(run("com.google.Chrome", .absent).1, "catchall", "no URL (no window) is not a match")
        let editor = run("com.apple.TextEdit", .value("https://github.com/a/b"))
        XCTAssertEqual(editor.1, "catchall")
        XCTAssertEqual(editor.2, [], "the app term fails first, so the URL is never read")
    }

    /// R12f: the front app changed during the slow read: nothing is erased or run.
    func testFrontChangeDuringSlowReadErasesNothing() {
        let desktop = FakeDesktop(app: "com.google.Chrome", focus: .text, fieldText: "x",
                                  facts: [.url: .value("https://github.com/")], appAfterSlowRead: "com.apple.TextEdit")
        for c in "@@@" { desktop.key(c) }
        let rule = Rule(trigger: "@@@", when: When(focus: .textField, facts: [Term(fact: .url, globs: ["*"])]),
                        output: Guarded(primary: .shell("x")))
        var lines: [String] = []
        var engine = Engine(config: KeypipeConfig(rules: [rule]), desktop: desktop, shell: { _, _, _, _ in
            XCTFail("nothing runs")
            return .exited(0, stdout: "")
        }, emit: { lines.append($0) })
        XCTAssertEqual(engine.fire("@@@"), .blocked("front-changed"))
        XCTAssertEqual(desktop.fieldText, "x@@@")
        XCTAssertTrue(lines.contains("keypipe front-changed @@@"))
    }

    /// After a slow read the gates are taken again, not only the app: a password field in the same
    /// browser, or a field the user kept typing into, stops the fire before any Backspace.
    func testSlowReadRetakesTheGatesBeforeErasing() {
        final class Shifting: Desktop {
            var snaps: [Snapshot]
            var text: String
            var backspaces = 0
            init(_ snaps: [Snapshot], text: String) { self.snaps = snaps; self.text = text }
            func snapshot() -> Snapshot { snaps.count > 1 ? snaps.removeFirst() : snaps[0] }
            func backspace(_ count: Int) { backspaces += count }
            func text(_ field: Field) -> String? { text }
            func setText(_ field: Field, _ text: String) -> Bool { true }
            func notify(_ text: String) {}
            func fact(_ name: FactName) -> FactRead { .value("https://github.com/") }
            func sameField(_ a: Field, _ b: Field) -> Bool { a == b }
        }
        let rule = Rule(trigger: "@@@", when: When(focus: .textField, facts: [Term(fact: .url, globs: ["*"])]),
                        output: Guarded(primary: .shell("x")))
        let field = Snapshot(app: "com.google.Chrome", focus: .text, field: Field(token: 0))
        let cases: [(Snapshot, String)] = [
            (Snapshot(app: "com.google.Chrome", focus: .nothing, secure: true), "x@@@"),  // moved to a password field
            (field, "x@@@ more"),                                                      // kept typing
            (Snapshot(app: "com.google.Chrome", focus: .text, field: Field(token: 1)), "x@@@"),  // another field, same app
        ]
        for (later, text) in cases {
            let desktop = Shifting([field, later], text: text)
            var engine = Engine(config: KeypipeConfig(rules: [rule]), desktop: desktop, shell: { _, _, _, _ in
                XCTFail("nothing runs")
                return .exited(0, stdout: "")
            }, emit: { _ in })
            XCTAssertEqual(engine.fire("@@@"), .blocked("front-changed"), "\(later)")
            XCTAssertEqual(desktop.backspaces, 0, "\(later)")
        }
    }

    /// The re-check after a slow read waits for a trigger key still on its way, like the fast path (R4e):
    /// a late key is a normal fire, not a moved-on field.
    func testSlowReadStillWaitsForALateTriggerKey() {
        let desktop = FakeDesktop(app: "com.google.Chrome", focus: .text, fieldText: "hello", keysPerRead: true,
                                  facts: [.url: .value("https://example.com/")])
        let rule = Rule(trigger: "@@@", when: When(focus: .textField, facts: [Term(fact: .url, globs: ["*"])]),
                        transform: Guarded(primary: "up"), output: Guarded(primary: .builtin(.replaceInput)))
        var engine = Engine(config: KeypipeConfig(rules: [rule]), desktop: desktop,
                            shell: { _, input, _, _ in .exited(0, stdout: input.uppercased()) }, emit: { _ in })
        for c in "@@@" { desktop.key(c) }
        XCTAssertEqual(engine.fire("@@@"), .replaced(rule: 0, text: "HELLO", viaFallback: false))
        XCTAssertEqual(desktop.fieldText, "HELLO")
    }

    /// P7: deny parsing and its fail-safe evaluation.
    func testDenyNeedsAppNextToASlowFactAndBlocksWhenUnreadable() throws {
        func load(_ json: String) throws -> KeypipeConfig { try loadConfig(data: Data(json.utf8)) }
        for (json, reason) in [
            (#"{"deny":[{"url":["*bank*"]}],"rules":[]}"#, "deny url requires app"),
            (#"{"deny":[{}],"rules":[]}"#, "empty deny entry"),
            (#"{"deny":[{"focus":"any"}],"rules":[]}"#, "unknown key focus"),
            (#"{"deny":{"app":["x"]},"rules":[]}"#, "deny must be an array"),
            (#"{"rules":[{"trigger":"@@@","when":{"url":"x"}}]}"#, "url must be an array of strings"),
        ] {
            XCTAssertThrowsError(try load(json)) { XCTAssertEqual(String(describing: $0), "keypipe: invalid config: \(reason)") }
        }
        let config = try load(#"{"deny":[{"app":["com.google.Chrome"],"url":["*bank.example*"]}],"rules":[{"trigger":"@@@"}]}"#)
        for (url, expected) in [(FactRead.value("https://bank.example/x"), FireResult.blocked("deny")),
                                (.value("https://github.com"), .delivered(rule: 0, viaFallback: false)),
                                (.unreadable("timeout"), .unreadable(fact: "url", reason: "timeout"))] {
            let desktop = FakeDesktop(app: "com.google.Chrome", focus: .nothing, facts: [.url: url])
            var engine = Engine(config: config, desktop: desktop, shell: { _, _, _, _ in .exited(0, stdout: "") }, emit: { _ in })
            XCTAssertEqual(engine.fire("@@@"), expected, "\(url)")
            if case .unreadable = url { XCTAssertEqual(desktop.notifications, ["@@@: deny cannot read url: timeout"], "a stopped fire says why") }
        }
        let editor = FakeDesktop(app: "com.apple.TextEdit", focus: .nothing, facts: [.url: .value("https://bank.example/")])
        var engine = Engine(config: config, desktop: editor, shell: { _, _, _, _ in .exited(0, stdout: "") }, emit: { _ in })
        XCTAssertNotEqual(engine.fire("@@@"), .blocked("deny"))
        XCTAssertEqual(editor.reads, [], "deny never asks the browser while another app is in front")
    }

    /// P8: glob matching keeps every exact bundle id an exact match, and `*` crosses "/".
    func testGlobsKeepExactIdsExact() {
        let ids = ["com.apple.TextEdit", "com.apple.Terminal", "com.googlecode.iterm2", "com.google.Chrome",
                   "com.github.wez.wezterm", "com.mitchellh.ghostty", "com.tinyspeck.slackmacgap", "editor", "terminal"]
        for id in ids {
            let term = Term(fact: .app, globs: [id])
            for other in ids { XCTAssertEqual(term.matches(other), id == other, "\(id) vs \(other)") }
        }
        XCTAssertTrue(Term(fact: .app, globs: ["com.apple.*"]).matches("com.apple.TextEdit"))
        XCTAssertTrue(Term(fact: .url, globs: ["https://github.com/*/pull/*"]).matches("https://github.com/a/b/pull/3"))
    }

    func testFrontTabScriptOnlyForKnownBrowsers() {
        XCTAssertNotNil(frontTabURLScript("com.google.Chrome"))
        XCTAssertNotNil(frontTabURLScript("com.apple.Safari"))
        XCTAssertNil(frontTabURLScript("com.apple.TextEdit"))
    }
}
