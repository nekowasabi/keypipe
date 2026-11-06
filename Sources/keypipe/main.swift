import Foundation

#if canImport(Glibc)
    import Glibc
#endif
#if os(macOS)
    import AppKit
#endif

private func emit(_ line: String) {
    print(line)
    fflush(stdout)
}

let usage = """
    usage: keypipe [--config FILE]                          run the daemon (macOS)
           keypipe [--config FILE] --line TRIGGER [--app BUNDLE_ID] [--report] < line
           keypipe [--config FILE] --rule NAME [--app BUNDLE_ID] [--report] < input
           keypipe [--config FILE] --triggers
           keypipe [--config FILE] [--context FILE] --smoke-feed KEYS [--smoke-hotkey CHORD]
           keypipe [--config FILE] [--context FILE] --feed-stdin
           keypipe --probe
           keypipe --selection-context                    links and page of the copied selection
    """
/// The parsed command line: flags present, and the value of each flag that takes one.
/// Why one parse: an unknown argument (a typo, --help) used to fall through and start the daemon
/// silently, and looking flags up by position read a value such as `--line --config` as a flag.
let (flags, values): (Set<String>, [String: String]) = {
    let args = CommandLine.arguments
    let takesValue: Set = [
        "--config", "--context", "--line", "--rule", "--app", "--smoke-feed", "--smoke-hotkey",
    ]
    let alone: Set = [
        "--job", "--probe", "--triggers", "--report", "--feed-stdin", "--selection-context",
    ]
    func refuse(_ why: String) -> Never {
        fputs("keypipe: \(why)\n\(usage)\n", stderr)
        exit(2)
    }
    var flags = Set<String>()
    var values: [String: String] = [:]
    var index = 1
    while index < args.count {
        let arg = args[index]
        if arg == "--help" || arg == "-h" {
            emit(usage)
            exit(0)
        }
        // Why: which of two values wins is a guess either way; nothing passes a flag twice.
        if flags.contains(arg) { refuse("\(arg) given twice") }
        if takesValue.contains(arg) {
            guard index + 1 < args.count else { refuse("\(arg) needs a value") }
            flags.insert(arg)
            values[arg] = args[index + 1]
            index += 2
            continue
        }
        guard alone.contains(arg) else { refuse("unknown argument \(arg)") }
        flags.insert(arg)
        index += 1
    }
    // A modifier without its mode would fall through to the daemon as well.
    for modifier in ["--report", "--app"]
    where flags.contains(modifier) && !flags.contains("--line") && !flags.contains("--rule") {
        refuse("\(modifier) needs --line or --rule")
    }
    // Before the config is read, like every other bad argument (exit 2, not the config's 1).
    if values["--line"]?.isEmpty == true { refuse("--line needs a trigger") }
    if values["--rule"]?.isEmpty == true { refuse("--rule needs a name") }
    // Why: the branches below run the first mode they find, so a second mode was silently
    // dropped. --smoke-feed and --smoke-hotkey are one mode (they run together).
    let modes = [
        "--job", "--probe", "--triggers", "--line", "--rule", "--smoke-feed", "--feed-stdin",
        "--selection-context",
    ].filter {
        flags.contains($0) || ($0 == "--smoke-feed" && flags.contains("--smoke-hotkey"))
    }
    if modes.count > 1 { refuse("pick one mode, got \(modes.joined(separator: " "))") }
    return (flags, values)
}()
if flags.contains("--job") { runJobProcess() }
if flags.contains("--probe") {
    var probe: [String: Any] = ["trusted": false, "focus": "none", "focusIsTextField": false]
    #if os(macOS)
        probe["trusted"] = MacDesktop.trusted
        let mac = MacDesktop()
        let snapshot = mac.snapshot()
        probe["app"] = snapshot.app ?? NSNull()
        switch snapshot.focus {
        case .text: probe["focus"] = "textField"
        case .composing: probe["focus"] = "composing"
        case .terminal: probe["focus"] = "terminal"
        case .nothing: probe["focus"] = "none"
        }
        probe["focusIsTextField"] = snapshot.focus == .text
        if let field = snapshot.field { probe["fieldText"] = mac.text(field) ?? NSNull() }
    #endif
    let data = try! JSONSerialization.data(
        withJSONObject: probe, options: [.sortedKeys, .withoutEscapingSlashes])
    emit(String(decoding: data, as: UTF8.self))
    exit(0)
}

// selection-prompt.sh calls this between its Cmd+C and putting the old clipboard back.
// Why exit 0 with nothing printed on any failure: the context is extra, the selection still goes.
if flags.contains("--selection-context") {
    #if os(macOS)
        let context = selectionContext(
            readSelectionCopy(), axLinks: selectedLinkURLs,
            tabURL: {
                if case .value(let url) = MacDesktop().fact(.url) { return url }
                return nil
            })
        if !context.isEmpty { emit(context) }
    #endif
    exit(0)
}

/// $XDG_CONFIG_HOME/keypipe/config.json, or ~/.config/keypipe/config.json.
let defaultConfigFile: String = {
    let environment = ProcessInfo.processInfo.environment
    let base =
        environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        ?? NSString(string: "~/.config").expandingTildeInPath
    return base + "/keypipe/config.json"
}()
let configFile = values["--config"] ?? defaultConfigFile
let loaded: KeypipeConfig
let configBytes: Data
let fake: FakeDesktop
do {
    configBytes = try readConfigData(path: configFile)
    loaded = try loadConfig(data: configBytes)
    if let path = values["--context"] {
        fake = try FakeDesktop(path: path)
    } else {
        fake = FakeDesktop()
    }
} catch {
    fputs("\(error)\n", stderr)
    if values["--config"] == nil {
        fputs(
            "keypipe: no --config given; copy config.example.json to \(defaultConfigFile)\n", stderr
        )
    }
    exit(1)
}

let spawnJob: (Job) -> Bool = {
    startJob($0, configPath: configFile, configBytes: configBytes, emit: emit)
}

if flags.contains("--triggers") {
    var seen = Set<String>()
    for rule in loaded.rules {
        if case .text(let text) = rule.trigger, seen.insert(text).inserted { emit(text) }
    }
    exit(0)
}

// The zsh widget's bridge (--line) and voice-switch's call by name (--rule): stdin is the line
// without the trigger, stdout the new line.
if flags.contains("--line") || flags.contains("--rule") {
    let trigger: Trigger
    var named: Int?
    if let name = values["--rule"] {
        guard let index = loaded.rules.firstIndex(where: { $0.name == name }) else {
            fputs("keypipe: no rule named \(name)\n", stderr)
            exit(2)
        }
        named = index
        trigger = loaded.rules[index].trigger
    } else {
        trigger = .text(values["--line"] ?? "")
    }
    var app = values["--app"]
    #if os(macOS)
        if app == nil { app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    #endif
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    // Why: --line's stdin is the line before the trigger the user typed; a rule called by name
    // was never typed, so its line is the input alone.
    let suffix: String
    if named == nil, case .text(let text) = trigger { suffix = text } else { suffix = "" }
    let desktop = LineDesktop(app: app, line: input + suffix)
    // Why: stdout carries only the line, so the transcript goes to stderr.
    let toStderr: (String) -> Void = { fputs($0 + "\n", stderr) }
    var engine = Engine(
        config: loaded, desktop: desktop, shell: runShell, emit: toStderr,
        background: {
            startJob($0, configPath: configFile, configBytes: configBytes, emit: toStderr)
        })
    let result = named.map { engine.fire(rule: $0, input: input) } ?? engine.fire(trigger)
    // Why: --report is for callers that act on the outcome (the verify skills). Plain --line keeps
    // the zsh widget's contract byte for byte: the line on stdout, exit 0 on a hit, 2 otherwise.
    if flags.contains("--report") {
        FileHandle.standardOutput.write(Data((result.reportJSON + "\n").utf8))
        exit(0)
    }
    guard result.isHit else { exit(2) }
    FileHandle.standardOutput.write(Data((desktop.line ?? input).utf8))
    exit(0)
}

let seed = values["--smoke-feed"]
let chord = values["--smoke-hotkey"]
if seed != nil || chord != nil {
    var engine = Engine(
        config: loaded, desktop: fake, shell: runShell, emit: emit, background: spawnJob)
    for character in seed ?? "" {
        fake.key(character)
        engine.key(character)
    }
    if let chord {
        do { engine.hotkey(try Hotkey.parse(chord)) } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }
    emit("keypipe smoke-feed hits \(engine.hits)")
    emit("keypipe field \(jsonString(fake.fieldText))")
    exit(engine.hits > 0 ? 0 : 2)
}

if flags.contains("--feed-stdin") {
    var engine = Engine(
        config: loaded, desktop: fake, shell: runShell, emit: emit, background: spawnJob)
    emit("keypipe started with \(loaded.rules.count) rule(s) from \(configFile)")
    while let line = readLine(strippingNewline: false) {
        for character in line {
            fake.key(character)
            engine.key(character)
        }
    }
    emit("keypipe field \(jsonString(fake.fieldText))")
    exit(0)
}

#if os(macOS)
    guard MacDesktop.trusted else {
        fputs(
            "keypipe: Accessibility not granted; allow this binary in System Settings > Privacy & Security > Accessibility\n",
            stderr)
        exit(1)
    }
    let desktop = MacDesktop()
    var live = LiveConfig(path: configFile, bytes: configBytes)
    func daemonEngine(_ config: KeypipeConfig) -> Engine {
        Engine(
            config: config, desktop: desktop, shell: runShell, emit: emit,
            background: {
                startJob($0, configPath: configFile, configBytes: live.bytes, emit: emit)
            })
    }
    var engine = daemonEngine(loaded)
    // Why: Engine.key blocks on shells and erase readback; the tap callback must not.
    let queue = DispatchQueue(label: "keypipe.engine")
    guard
        let tap = MacKeyTap(onInput: { input in
            queue.async {
                let reloaded = live.poll { reason in
                    emit("keypipe reload-failed \(jsonString(reason))")
                    notifyUser("keypipe: config not reloaded, keeping the old rules: \(reason)")
                }
                if let reloaded {
                    engine = daemonEngine(reloaded)
                    emit("keypipe reloaded \(reloaded.rules.count) rule(s) from \(configFile)")
                }
                switch input {
                case .char(let character): engine.key(character)
                case .hotkey(let hotkey): engine.hotkey(hotkey)
                }
            }
        })
    else {
        fputs("keypipe: could not create the event tap\n", stderr)
        exit(1)
    }
    emit("keypipe started with \(loaded.rules.count) rule(s) from \(configFile)")
    // Why: the busy spinner is an AppKit window, which a bare CFRunLoopRun does not drive.
    // Accessory keeps keypipe off the Dock and the menu bar; the tap is on .commonModes.
    NSApplication.shared.setActivationPolicy(.accessory)
    withExtendedLifetime(tap) { NSApplication.shared.run() }
#else
    fputs("keypipe: the daemon needs macOS; use --smoke-feed or --feed-stdin here\n", stderr)
    exit(1)
#endif
