import Foundation

#if canImport(Glibc)
    import Glibc
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
if args.contains("--probe") {
    var probe: [String: Any] = ["trusted": false, "focus": "none", "focusIsTextField": false]
    #if os(macOS)
        probe["trusted"] = MacDesktop.trusted
        let mac = MacDesktop()
        let snapshot = mac.snapshot()
        probe["app"] = snapshot.app ?? NSNull()
        probe["focus"] = snapshot.focus == .text ? "textField" : snapshot.focus == .composing ? "composing" : "none"
        probe["focusIsTextField"] = snapshot.focus == .text
        if let field = snapshot.field { probe["fieldText"] = mac.text(field) ?? NSNull() }
    #endif
    let data = try! JSONSerialization.data(withJSONObject: probe, options: [.sortedKeys, .withoutEscapingSlashes])
    emit(String(decoding: data, as: UTF8.self))
    exit(0)
}

let configFile = argument("--config", in: args) ?? "config.example.json"
let loaded: KeypipeConfig
let fake: FakeDesktop
do {
    loaded = try loadConfig(path: configFile)
    if let path = argument("--context", in: args) { fake = try FakeDesktop(path: path) }
    else { fake = FakeDesktop() }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}

let seed = argument("--smoke-feed", in: args)
let chord = argument("--smoke-hotkey", in: args)
if seed != nil || chord != nil {
    var engine = Engine(config: loaded, desktop: fake, shell: runShell, emit: emit)
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
    var engine = Engine(config: loaded, desktop: fake, shell: runShell, emit: emit)
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
    var engine = Engine(config: loaded, desktop: MacDesktop(), shell: runShell, emit: emit)
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
