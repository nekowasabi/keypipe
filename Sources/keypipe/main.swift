import Foundation

#if canImport(Glibc)
    import Glibc
#endif
#if os(macOS)
    import AppKit
#endif

private func argument(_ flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

private func emit(_ line: String) {
    print(line)
    fflush(stdout)
}

let args = CommandLine.arguments
let usage = """
    usage: keypipe [--config FILE]                          run the daemon (macOS)
           keypipe [--config FILE] --line TRIGGER [--app BUNDLE_ID] [--report] < line
           keypipe [--config FILE] --triggers
           keypipe [--config FILE] [--context FILE] --smoke-feed KEYS [--smoke-hotkey CHORD]
           keypipe [--config FILE] [--context FILE] --feed-stdin
           keypipe --probe
    """
// Why: an unknown argument (a typo, --help) used to fall through and start the daemon silently.
do {
    let takesValue: Set = ["--config", "--context", "--line", "--app", "--smoke-feed", "--smoke-hotkey"]
    let alone: Set = ["--job", "--probe", "--triggers", "--report", "--feed-stdin"]
    var index = 1
    while index < args.count {
        let arg = args[index]
        if arg == "--help" || arg == "-h" { emit(usage); exit(0) }
        if takesValue.contains(arg) { index += 2; continue }
        guard alone.contains(arg) else {
            fputs("keypipe: unknown argument \(arg)\n\(usage)\n", stderr)
            exit(2)
        }
        index += 1
    }
}
if args.contains("--job") { runJobProcess() }
if args.contains("--probe") {
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
    let data = try! JSONSerialization.data(withJSONObject: probe, options: [.sortedKeys, .withoutEscapingSlashes])
    emit(String(decoding: data, as: UTF8.self))
    exit(0)
}

/// $XDG_CONFIG_HOME/keypipe/config.json, or ~/.config/keypipe/config.json.
let defaultConfigFile: String = {
    let environment = ProcessInfo.processInfo.environment
    let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        ?? NSString(string: "~/.config").expandingTildeInPath
    return base + "/keypipe/config.json"
}()
let configFile = argument("--config", in: args) ?? defaultConfigFile
let loaded: KeypipeConfig
let configBytes: Data
let fake: FakeDesktop
do {
    configBytes = try readConfigData(path: configFile)
    loaded = try loadConfig(data: configBytes)
    if let path = argument("--context", in: args) { fake = try FakeDesktop(path: path) }
    else { fake = FakeDesktop() }
} catch {
    fputs("\(error)\n", stderr)
    if argument("--config", in: args) == nil {
        fputs("keypipe: no --config given; copy config.example.json to \(defaultConfigFile)\n", stderr)
    }
    exit(1)
}

let spawnJob: (Job) -> Bool = { startJob($0, configPath: configFile, configBytes: configBytes, emit: emit) }

if args.contains("--triggers") {
    var seen = Set<String>()
    for rule in loaded.rules {
        if case .text(let text) = rule.trigger, seen.insert(text).inserted { emit(text) }
    }
    exit(0)
}

// The zsh widget's bridge: stdin is the line without the trigger, stdout the new line.
if args.contains("--line") {
    guard let trigger = argument("--line", in: args), !trigger.isEmpty else {
        fputs("keypipe: --line needs a trigger\n", stderr)
        exit(1)
    }
    var app = argument("--app", in: args)
    #if os(macOS)
        if app == nil { app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    #endif
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let desktop = LineDesktop(app: app, line: input + trigger)
    // Why: stdout carries only the line, so the transcript goes to stderr.
    let toStderr: (String) -> Void = { fputs($0 + "\n", stderr) }
    var engine = Engine(config: loaded, desktop: desktop, shell: runShell, emit: toStderr,
                        background: { startJob($0, configPath: configFile, configBytes: configBytes, emit: toStderr) })
    let result = engine.fire(.text(trigger))
    // Why: --report is for callers that act on the outcome (voice-switch). Plain --line keeps
    // the zsh widget's contract byte for byte: the line on stdout, exit 0 on a hit, 2 otherwise.
    if args.contains("--report") {
        FileHandle.standardOutput.write(Data((result.reportJSON + "\n").utf8))
        exit(0)
    }
    guard result.isHit else { exit(2) }
    FileHandle.standardOutput.write(Data((desktop.line ?? input).utf8))
    exit(0)
}

let seed = argument("--smoke-feed", in: args)
let chord = argument("--smoke-hotkey", in: args)
if seed != nil || chord != nil {
    var engine = Engine(config: loaded, desktop: fake, shell: runShell, emit: emit, background: spawnJob)
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

if args.contains("--feed-stdin") {
    var engine = Engine(config: loaded, desktop: fake, shell: runShell, emit: emit, background: spawnJob)
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
        fputs("keypipe: Accessibility not granted; allow this binary in System Settings > Privacy & Security > Accessibility\n", stderr)
        exit(1)
    }
    var engine = Engine(config: loaded, desktop: MacDesktop(), shell: runShell, emit: emit, background: spawnJob)
    // Why: Engine.key blocks on shells and erase readback; the tap callback must not.
    let queue = DispatchQueue(label: "keypipe.engine")
    guard let tap = MacKeyTap(onInput: { input in
        queue.async {
            switch input {
            case .char(let character): engine.key(character)
            case .hotkey(let hotkey): engine.hotkey(hotkey)
            }
        }
    }) else {
        fputs("keypipe: could not create the event tap\n", stderr)
        exit(1)
    }
    emit("keypipe started with \(loaded.rules.count) rule(s) from \(configFile)")
    withExtendedLifetime(tap) { CFRunLoopRun() }
#else
    fputs("keypipe: the daemon needs macOS; use --smoke-feed or --feed-stdin here\n", stderr)
    exit(1)
#endif
