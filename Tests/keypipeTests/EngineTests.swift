import XCTest

@testable import keypipe

final class EngineTests: XCTestCase {
    private func run(
        _ keys: String = "@@@", rules: [Rule], desktop: FakeDesktop,
        shell: @escaping (String, String, [String: String], TimeInterval) -> ShellOutcome = {
            _, input, _, _ in .exited(0, stdout: input)
        }
    ) -> (Int, [String]) {
        var lines: [String] = []
        var engine = Engine(config: KeypipeConfig(rules: rules), desktop: desktop, shell: shell) {
            lines.append($0)
        }
        for character in keys {
            desktop.key(character)
            engine.key(character)
        }
        return (engine.hits, lines)
    }

    func testHotkeyReadsFieldWithoutErasingAndIgnoresUnconfiguredChords() throws {
        let ctrlAt = try Hotkey.parse("ctrl+@")
        let desktop = FakeDesktop(focus: .text, fieldText: "hello")
        let rules = [
            Rule(
                trigger: .hotkey(ctrlAt), when: When(focus: .textField),
                transform: Guarded(primary: "tr"), output: Guarded(primary: .builtin(.replaceInput))
            ),
            Rule(trigger: "@@@"),
        ]
        var lines: [String] = []
        var engine = Engine(
            config: KeypipeConfig(rules: rules), desktop: desktop,
            shell: { _, input, _, _ in
                XCTAssertEqual(input, "hello")
                return .exited(0, stdout: "HELLO")
            },
            emit: { lines.append($0) })
        engine.hotkey(try Hotkey.parse("cmd+c"))
        XCTAssertEqual(lines, [])
        engine.key("@")
        engine.key("@")
        engine.hotkey(ctrlAt)
        XCTAssertEqual(engine.hits, 1)
        XCTAssertTrue(lines.contains("keypipe matched ctrl+@ rule 0"))
        XCTAssertTrue(lines.contains("keypipe erase 0"))
        XCTAssertEqual(desktop.fieldText, "HELLO")
        engine.key("@")
        XCTAssertEqual(engine.hits, 1, "chord resets the text buffer")
    }

    func testTransformFallbackRunsOnceWithSameInputAndFailureReason() {
        for (outcome, token) in [
            (ShellOutcome.exited(3, stdout: "junk"), "exit 3"), (.timedOut(seconds: 1), "timeout"),
            (.exited(0, stdout: ""), "empty"),
        ] {
            let desktop = FakeDesktop(focus: .text, fieldText: "hello")
            let rule = Rule(
                trigger: "@@@", when: When(focus: .textField),
                transform: Guarded(primary: "primary", onFail: "fallback"),
                output: Guarded(primary: .builtin(.replaceInput)))
            var calls: [String] = []
            let (_, lines) = run(rules: [rule], desktop: desktop) { script, input, env, timeout in
                calls.append(script)
                XCTAssertEqual(input, "hello")
                XCTAssertEqual(timeout, 30)
                if script == "primary" {
                    XCTAssertNil(env["KEYPIPE_FAILURE"])
                    return outcome
                }
                XCTAssertEqual(env["KEYPIPE_FAILURE"], token)
                return .exited(0, stdout: "HELLO")
            }
            XCTAssertEqual(calls, ["primary", "fallback"])
            XCTAssertTrue(lines.contains("keypipe fallback transform exit 0"), token)
            XCTAssertEqual(desktop.fieldText, "HELLO", token)
            XCTAssertEqual(desktop.notifications, [], token)
        }
    }

    /// A failing transform, so a hide placed only on the success path would fail this test.
    func testBusyShownDuringTransformAndHiddenAfterFailure() {
        let desktop = FakeDesktop(focus: .text, fieldText: "hello")
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField), transform: Guarded(primary: "exit 3"),
            output: Guarded(primary: .builtin(.replaceInput)))
        _ = run(rules: [rule], desktop: desktop) { _, _, _, _ in
            XCTAssertEqual(desktop.busy, [true], "shown while the transform runs")
            return .exited(3, stdout: "")
        }
        XCTAssertEqual(desktop.busy, [true, false])
        let quiet = FakeDesktop(focus: .text, fieldText: "hello")
        _ = run("@@x", rules: [rule], desktop: quiet)
        XCTAssertEqual(quiet.busy, [], "no match, no spinner")
    }

    func testFallbackFailureNotifiesWithoutRetrying() {
        let desktop = FakeDesktop(focus: .text, fieldText: "hello")
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField),
            transform: Guarded(primary: "exit 3", onFail: "exit 4"),
            output: Guarded(primary: .builtin(.replaceInput)))
        var calls = 0
        let (_, lines) = run(rules: [rule], desktop: desktop) { script, _, _, _ in
            calls += 1
            return .exited(script == "exit 3" ? 3 : 4, stdout: "")
        }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(lines.contains("keypipe fallback transform exit 4"))
        XCTAssertEqual(desktop.notifications, ["@@@ transform failed: exit 4"])
        XCTAssertEqual(desktop.fieldText, "hello")
    }

    func testOutputFallbackReceivesResultAndReason() {
        let desktop = FakeDesktop(focus: .text, fieldText: "hello")
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField),
            output: Guarded(primary: .shell("send"), onFail: .shell("keep")))
        var seen: [(String, String?)] = []
        let (_, lines) = run(rules: [rule], desktop: desktop) { script, input, env, _ in
            seen.append((script, env["KEYPIPE_FAILURE"]))
            XCTAssertEqual(input, "hello")
            return script == "send" ? .timedOut(seconds: 30) : .exited(0, stdout: "")
        }
        XCTAssertEqual(seen.map(\.0), ["send", "keep"])
        XCTAssertEqual(seen.last?.1, "timeout")
        XCTAssertTrue(lines.contains("keypipe output-shell timeout 30"))
        XCTAssertTrue(lines.contains("keypipe fallback output-shell exit 0"))
    }

    func testDelayedWriteCountsAsWrittenNotIgnored() {
        let desktop = FakeDesktop(focus: .text, fieldText: "hello", writePerRead: true)
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField),
            transform: Guarded(primary: "tr"), output: Guarded(primary: .builtin(.replaceInput)))
        let (_, lines) = run(rules: [rule], desktop: desktop) { _, _, _, _ in
            .exited(0, stdout: "HELLO")
        }
        XCTAssertTrue(lines.contains(#"keypipe apply replaceInput "HELLO""#))
        XCTAssertFalse(lines.contains { $0.hasPrefix("keypipe apply-failed") })
        XCTAssertEqual(desktop.fieldText, "HELLO")
        XCTAssertEqual(desktop.notifications, [])
    }

    func testIgnoredWriteFallsBackAndGoneFieldNotifiesByDefault() {
        let ignoring = FakeDesktop(focus: .text, fieldText: "hello", ignoresWrite: true)
        let withFallback = Rule(
            trigger: "@@@", when: When(focus: .textField), transform: Guarded(primary: "tr"),
            output: Guarded(primary: .builtin(.replaceInput), onFail: .shell("pbcopy")))
        var copied: String?
        let (_, lines) = run(rules: [withFallback], desktop: ignoring) { script, input, env, _ in
            guard script == "pbcopy" else { return .exited(0, stdout: "HELLO") }
            copied = input
            XCTAssertEqual(env["KEYPIPE_FAILURE"], "ignored")
            return .exited(0, stdout: "")
        }
        XCTAssertTrue(lines.contains("keypipe apply-failed replaceInput ignored"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("keypipe apply replaceInput") })
        XCTAssertEqual(copied, "HELLO")
        XCTAssertEqual(ignoring.fieldText, "hello")

        let vanishing = FakeDesktop(focus: .text, fieldText: "hello", goneAfterErase: true)
        let plain = Rule(
            trigger: "@@@", when: When(focus: .textField),
            transform: Guarded(primary: "tr"), output: Guarded(primary: .builtin(.replaceInput)))
        let (_, lines2) = run(rules: [plain], desktop: vanishing) { _, _, _, _ in
            .exited(0, stdout: "HELLO")
        }
        XCTAssertTrue(lines2.contains("keypipe apply-failed replaceInput gone"))
        XCTAssertEqual(vanishing.notifications, ["HELLO"])
    }

    func testComposingDoesNotFireOrErase() {
        let desktop = FakeDesktop(focus: .composing, fieldText: "hello")
        let (hits, lines) = run(
            rules: [Rule(trigger: "@@@")], desktop: desktop,
            shell: { _, _, _, _ in
                XCTFail("shell called during composition")
                return .exited(0, stdout: "")
            })
        XCTAssertEqual(hits, 0)
        XCTAssertEqual(lines, ["keypipe composing @@@"])
        XCTAssertEqual(desktop.fieldText, "hello@@@")
    }

    func testBackspaceAndRewriteRemoveOnlyOneTrigger() {
        for ignores in [false, true] {
            let desktop = FakeDesktop(focus: .text, fieldText: "@@@", ignoresBackspace: ignores)
            let rule = Rule(trigger: "@@@", when: When(focus: .textField))
            let (hits, lines) = run(rules: [rule], desktop: desktop)
            XCTAssertEqual(hits, 1)
            XCTAssertEqual(desktop.fieldText, "@@@")
            XCTAssertEqual(lines.contains("keypipe erase-rewrite"), ignores)
        }
    }

    func testEraseWaitsForEveryBackspaceBeforeReading() {
        let desktop = FakeDesktop(focus: .text, fieldText: "hello", backspacePerRead: true)
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField),
            transform: Guarded(primary: "tr"), output: Guarded(primary: .builtin(.replaceInput)))
        let (_, lines) = run(rules: [rule], desktop: desktop) { _, input, _, _ in
            XCTAssertEqual(input, "hello")
            return .exited(0, stdout: "HELLO")
        }
        XCTAssertFalse(lines.contains("keypipe erase-rewrite"))
        XCTAssertEqual(desktop.fieldText, "HELLO")
    }

    func testEraseWaitsForTheTriggerToLandBeforeBackspacing() {
        let desktop = FakeDesktop(focus: .text, fieldText: "hello", keysPerRead: true)
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField),
            transform: Guarded(primary: "tr"), output: Guarded(primary: .builtin(.replaceInput)))
        let (_, lines) = run(rules: [rule], desktop: desktop) { _, input, _, _ in
            XCTAssertEqual(input, "hello")
            return .exited(0, stdout: "HELLO")
        }
        XCTAssertFalse(lines.contains("keypipe erase-rewrite"))
        XCTAssertEqual(desktop.fieldText, "HELLO")
    }

    func testEmptyTransformOutputNotifiesInsteadOfWipingField() {
        let desktop = FakeDesktop(focus: .text, fieldText: "hello")
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField),
            transform: Guarded(primary: "true"), output: Guarded(primary: .builtin(.replaceInput)))
        let (_, lines) = run(rules: [rule], desktop: desktop) { _, _, _, _ in .exited(0, stdout: "")
        }
        XCTAssertTrue(lines.contains("keypipe transform empty"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("keypipe apply replaceInput") })
        XCTAssertEqual(desktop.notifications, ["@@@ transform failed: empty"])
        XCTAssertEqual(desktop.fieldText, "hello")
    }

    func testAnySuppliesEmptyInputAndErasesOnlyInTextFields() {
        for (focus, late) in [(Focus.text, false), (.text, true), (.nothing, false)] {
            let desktop = FakeDesktop(
                app: "editor", focus: focus, fieldText: "hello", keysPerRead: late)
            let rule = Rule(trigger: "@@@", output: Guarded(primary: .shell("send")))
            var called = false
            let (_, lines) = run(rules: [rule], desktop: desktop) { script, input, env, timeout in
                called = true
                XCTAssertEqual(script, "send")
                XCTAssertEqual(input, "")
                XCTAssertEqual(env, ["KEYPIPE_APP": "editor"])
                XCTAssertEqual(timeout, 30)
                return .exited(0, stdout: "")
            }
            XCTAssertTrue(called)
            XCTAssertTrue(lines.contains("keypipe erase \(focus == .text ? 3 : 0)"))
            XCTAssertEqual(desktop.fieldText, focus == .text ? "hello" : "hello@@@")
        }
    }

    /// --rule: the named rule runs, not an earlier rule of the same trigger, and its input is the
    /// caller's text in every focus (with --line, focus any gets empty input).
    func testFireRuleRunsOnlyThatRuleWithTheCallersInputInEveryFocus() throws {
        for trigger in [Trigger.text("@@@"), .hotkey(try Hotkey.parse("ctrl+cmd+g"))] {
            for focus in [When.Focus.any, .textField] {
                let suffix: String
                if case .text(let text) = trigger { suffix = text } else { suffix = "" }
                let desktop = LineDesktop(app: "editor", line: "note" + suffix)
                let rules = [
                    Rule(trigger: trigger, output: Guarded(primary: .shell("first"))),
                    Rule(
                        trigger: trigger, when: When(focus: focus),
                        output: Guarded(primary: .shell("second")), name: "b"),
                ]
                var ran: [String] = []
                var engine = Engine(
                    config: KeypipeConfig(rules: rules), desktop: desktop,
                    shell: { script, input, _, _ in
                        ran.append("\(script):\(input)")
                        return .exited(0, stdout: "")
                    }, emit: { _ in })
                XCTAssertEqual(
                    engine.fire(rule: 1, input: "note"), .delivered(rule: 1, viaFallback: false),
                    "\(trigger) \(focus)")
                XCTAssertEqual(ran, ["second:note"], "\(trigger) \(focus)")
            }
        }
    }

    func testFireRuleStopsAtDenyAndHandsTheInputToABackgroundJob() {
        let rule = Rule(
            trigger: "@@@",
            output: Guarded(primary: .shell(ShellOutput(script: "curl", background: true))),
            name: "a")
        for (app, denied) in [("bank", true), ("editor", false)] {
            var jobs: [Job] = []
            var engine = Engine(
                config: KeypipeConfig(
                    rules: [rule], deny: [Conditions([Term(fact: .app, globs: ["bank"])])]),
                desktop: LineDesktop(app: app, line: "note@@@"),
                shell: { _, _, _, _ in
                    XCTFail("the job, not the caller, runs the stages")
                    return .exited(0, stdout: "")
                }, emit: { _ in },
                background: {
                    jobs.append($0)
                    return true
                })
            let result = engine.fire(rule: 0, input: "note")
            if denied {
                XCTAssertEqual(result, .blocked("deny"))
                XCTAssertEqual(jobs, [])
            } else {
                XCTAssertEqual(result, .started(rule: 0))
                XCTAssertEqual(
                    jobs, [Job(rule: 0, input: "note", environment: ["KEYPIPE_APP": "editor"])])
            }
        }
    }

    func testFailedTransformNotifiesAndPreservesErasedField() {
        let desktop = FakeDesktop(focus: .text, fieldText: "hello")
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField),
            transform: Guarded(primary: "exit 3"), output: Guarded(primary: .builtin(.replaceInput))
        )
        let (hits, lines) = run(rules: [rule], desktop: desktop) { _, input, _, _ in
            XCTAssertEqual(input, "hello")
            return .exited(3, stdout: "ignored")
        }
        XCTAssertEqual(hits, 1)
        XCTAssertTrue(lines.contains("keypipe transform exit 3"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("keypipe apply replaceInput") })
        XCTAssertEqual(desktop.notifications, ["@@@ transform failed: exit 3"])
        XCTAssertEqual(desktop.fieldText, "hello")
    }

    func testNoMatchDoesNotEraseOrTryShorterTrigger() {
        let desktop = FakeDesktop(focus: .nothing)
        let rules = [Rule(trigger: "aab", when: When(focus: .textField)), Rule(trigger: "ab")]
        let (hits, lines) = run("aab", rules: rules, desktop: desktop)
        XCTAssertEqual(hits, 0)
        XCTAssertEqual(lines, ["keypipe nomatch aab"])
        XCTAssertEqual(desktop.fieldText, "aab")
    }

    func testTransformationFeedsReplacementAndKeepsUnicode() {
        let desktop = FakeDesktop(focus: .text, fieldText: "こんにちは")
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField),
            transform: Guarded(primary: "transform"),
            output: Guarded(primary: .builtin(.replaceInput)))
        let (_, lines) = run(rules: [rule], desktop: desktop) { _, input, _, _ in
            XCTAssertEqual(input, "こんにちは")
            return .exited(0, stdout: "Hello\nworld")
        }
        XCTAssertEqual(desktop.fieldText, "Hello\nworld")
        XCTAssertTrue(lines.contains(#"keypipe apply replaceInput "Hello\nworld""#))
    }

    func testContextRejectsCompositionWithoutTextField() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try #"{"focusIsTextField":false,"fieldText":"","composing":true}"#.write(
            to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try FakeDesktop(path: url.path)) {
            XCTAssertEqual(
                String(describing: $0),
                "keypipe: invalid config: composing requires focusIsTextField")
        }
    }

    func testTerminalFocusDoesNothingAtAll() {
        let desktop = FakeDesktop(
            app: "com.example.someterm", focus: .terminal, fieldText: "secret-token-123")
        let rule = Rule(
            trigger: "@@@", when: When(focus: .textField), output: Guarded(primary: .shell("send")))
        let (hits, lines) = run(
            rules: [rule, Rule(trigger: "@@@", output: Guarded(primary: .builtin(.notify)))],
            desktop: desktop
        ) { _, _, _, _ in
            XCTFail("no shell runs in a terminal")
            return .exited(0, stdout: "")
        }
        XCTAssertEqual(hits, 0)
        XCTAssertEqual(lines, ["keypipe terminal @@@"])
        XCTAssertEqual(desktop.fieldText, "secret-token-123@@@", "no Backspace")
        XCTAssertEqual(desktop.notifications, [])
    }

    func testBackgroundShellHandsTheReadInputToAJobAndReturns() {
        let desktop = FakeDesktop(app: "editor", focus: .text, fieldText: "note")
        let rule = Rule(
            trigger: "&&&", when: When(focus: .textField),
            transform: Guarded(primary: "tr"),
            output: Guarded(primary: .shell(ShellOutput(script: "curl", background: true))))
        var jobs: [Job] = []
        var lines: [String] = []
        var engine = Engine(
            config: KeypipeConfig(rules: [rule]), desktop: desktop,
            shell: { _, _, _, _ in
                XCTFail("the job, not the caller, runs the stages")
                return .exited(0, stdout: "")
            }, emit: { lines.append($0) },
            background: {
                jobs.append($0)
                return true
            })
        for character in "&&" {
            desktop.key(character)
            engine.key(character)
        }
        desktop.key("&")
        XCTAssertEqual(engine.fire("&&&"), .started(rule: 0))
        XCTAssertEqual(jobs, [Job(rule: 0, input: "note", environment: ["KEYPIPE_APP": "editor"])])
        XCTAssertTrue(lines.contains("keypipe background rule 0"))
        XCTAssertEqual(lines.last, #"keypipe hud &&& started "&&& → curl" none"#)
        XCTAssertEqual(desktop.fieldText, "note")
    }

    /// P2: a job that never started is not reported as started.
    func testFailedSpawnIsReportedAsFailedNotStarted() {
        let desktop = FakeDesktop(app: "editor", focus: .text, fieldText: "note&&&")
        let rule = Rule(
            trigger: "&&&", when: When(focus: .textField),
            output: Guarded(primary: .shell(ShellOutput(script: "curl", background: true))))
        var engine = Engine(
            config: KeypipeConfig(rules: [rule]), desktop: desktop,
            shell: { _, _, _, _ in .exited(0, stdout: "") }, emit: { _ in },
            background: { _ in false })
        XCTAssertEqual(engine.fire("&&&"), .failed(rule: 0, stage: .spawn, failure: "spawn"))
        XCTAssertEqual(engine.hits, 1)
    }

    /// P3: the job runs the parent's rules even after the file on disk changed.
    func testJobParsesTheParentsBytesNotTheFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .path
        let parent = Data(
            #"{"rules":[{"trigger":"a","output":{"shell":"first"}},{"trigger":"b","output":{"shell":"second"}}]}"#
                .utf8)
        try
            #"{"rules":[{"trigger":"b","output":{"shell":"second"}},{"trigger":"a","output":{"shell":"first"}}]}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let request = JobRequest(
            config: path, configBytes: parent, job: Job(rule: 0, input: "", environment: [:]))
        let decoded = try JSONDecoder().decode(JobRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(try jobConfig(decoded).rules[0].output.primary, .shell("first"))
        let legacy = JobRequest(config: path, configBytes: nil, job: request.job)
        XCTAssertEqual(
            try jobConfig(legacy).rules[0].output.primary, .shell("second"),
            "an older parent still works")
    }

    func testFireReportsWhatHappened() {
        func fire(
            _ rules: [Rule], _ desktop: FakeDesktop,
            _ shell: @escaping (String, String, [String: String], TimeInterval) -> ShellOutcome = {
                _, input, _, _ in .exited(0, stdout: input.uppercased())
            }
        ) -> FireResult {
            var engine = Engine(
                config: KeypipeConfig(rules: rules), desktop: desktop, shell: shell, emit: { _ in })
            return engine.fire("@@@")
        }
        let replace = Rule(
            trigger: "@@@", when: When(focus: .textField), transform: Guarded(primary: "up"),
            output: Guarded(primary: .builtin(.replaceInput)))
        XCTAssertEqual(
            fire([replace], FakeDesktop(focus: .text, fieldText: "hi@@@")),
            .replaced(rule: 0, text: "HI", viaFallback: false))
        XCTAssertEqual(fire([replace], FakeDesktop(focus: .nothing)), .noMatch)
        XCTAssertEqual(
            fire([replace], FakeDesktop(focus: .composing, fieldText: "hi@@@")),
            .blocked("composing"))
        XCTAssertEqual(fire([replace], FakeDesktop(focus: .terminal)), .blocked("terminal"))
        XCTAssertEqual(
            fire([replace], FakeDesktop(focus: .text, fieldText: "hi@@@")) { _, _, _, _ in
                .exited(2, stdout: "")
            },
            .failed(rule: 0, stage: .transform, failure: "exit 2"))
        XCTAssertEqual(
            fire([replace], FakeDesktop(focus: .text, fieldText: "hi@@@", goneAfterErase: true)),
            .failed(rule: 0, stage: .output, failure: "gone"))
        let send = Rule(
            trigger: "@@@", output: Guarded(primary: .shell("send"), onFail: .builtin(.notify)))
        XCTAssertEqual(
            fire([send], FakeDesktop(focus: .nothing)), .delivered(rule: 0, viaFallback: false))
        XCTAssertEqual(
            fire([send], FakeDesktop(focus: .nothing)) { _, _, _, _ in .exited(1, stdout: "") },
            .delivered(rule: 0, viaFallback: true))
    }

    func testJobRunsStagesAndNotifiesOnlyWhenTheShellFails() {
        let rule = Rule(
            trigger: "&&&",
            output: Guarded(primary: .shell(ShellOutput(script: "curl", background: true))))
        for (outcome, notified) in [
            (ShellOutcome.exited(0, stdout: ""), [String]()),
            (.timedOut(seconds: 2), ["&&& output failed: timeout"]),
        ] {
            let desktop = FakeDesktop()
            var lines: [String] = []
            let engine = Engine(
                config: KeypipeConfig(rules: [rule]), desktop: desktop,
                shell: { script, input, env, _ in
                    XCTAssertEqual(script, "curl")
                    XCTAssertEqual(input, "note")
                    XCTAssertEqual(env, ["KEYPIPE_APP": "editor"])
                    return outcome
                },
                emit: { lines.append($0) })
            engine.run(Job(rule: 0, input: "note", environment: ["KEYPIPE_APP": "editor"]))
            XCTAssertEqual(desktop.notifications, notified)
            if !notified.isEmpty { XCTAssertTrue(lines.contains("keypipe output-shell timeout 2")) }
        }
    }

    func testBoundedShellReportsTheJobLimitWhenItCutsAStageShort() {
        var given: [TimeInterval] = []
        let shell = boundedShell(limit: 2) { _, _, _, timeout in
            given.append(timeout)
            return .timedOut(seconds: Int(timeout))
        }
        XCTAssertEqual(
            shell("a", "", [:], 1), .timedOut(seconds: 1), "a shorter shellTimeout still applies")
        XCTAssertEqual(shell("b", "", [:], 30), .timedOut(seconds: 2))
        XCTAssertEqual(given[0], 1)
        XCTAssertLessThanOrEqual(given[1], 2)
    }
}
