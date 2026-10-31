import Foundation

#if canImport(Glibc)
    import Glibc
#endif

private var keepRunning = true

private func handleSignal(_ sig: Int32) { keepRunning = false }

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
    emit(#"{"trusted":false}"#)
    exit(0)
}

let configFile = argument("--config", in: args) ?? "config.example.json"
let loaded: KeypipeConfig
let desktop: FakeDesktop
do {
    loaded = try loadConfig(path: configFile)
    if let path = argument("--context", in: args) { desktop = try FakeDesktop(path: path) }
    else { desktop = FakeDesktop() }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
var engine = Engine(config: loaded, desktop: desktop, shell: runShell, emit: emit)

if let seed = argument("--smoke-feed", in: args) {
    for character in seed {
        desktop.key(character)
        engine.key(character)
    }
    emit("keypipe smoke-feed hits \(engine.hits)")
    emit("keypipe field \(jsonString(desktop.fieldText))")
    exit(engine.hits > 0 ? 0 : 2)
}

if args.contains("--feed-stdin") {
    emit("keypipe started with \(loaded.rules.count) rule(s) from \(configFile)")
    while let line = readLine(strippingNewline: false) {
        for character in line {
            desktop.key(character)
            engine.key(character)
        }
    }
    emit("keypipe field \(jsonString(desktop.fieldText))")
    exit(0)
}

signal(SIGINT, handleSignal)
signal(SIGTERM, handleSignal)
emit("keypipe started with \(loaded.rules.count) rule(s) from \(configFile)")
while keepRunning { Thread.sleep(forTimeInterval: 0.1) }
