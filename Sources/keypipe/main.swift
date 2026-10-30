import Foundation

#if canImport(Glibc)
    import Glibc
#endif

private var keepRunning = true

private func handleSignal(_ sig: Int32) {
    keepRunning = false
}

private func configPath(from args: [String]) -> String {
    if let flag = args.firstIndex(of: "--config"), flag + 1 < args.count {
        return args[flag + 1]
    }
    return "config.example.json"
}

private func smokeFeed(from args: [String]) -> String? {
    if let flag = args.firstIndex(of: "--smoke-feed"), flag + 1 < args.count {
        return args[flag + 1]
    }
    return nil
}

/// Feeds text through the matcher. On every hit runs the rule action,
/// then resets so the same trigger can fire again. Returns hit count.
private func feedAndRun(_ text: String, matcher: inout TriggerMatcher, logPath: String?) -> Int {
    var hits = 0
    for ch in text {
        if let rule = matcher.feed(ch) {
            hits += 1
            print("keypipe matched \(rule.trigger)")
            fflush(stdout)
            let status = runAction(rule.action, logPath: logPath)
            print("keypipe action exit \(status)")
            fflush(stdout)
            matcher.reset()
        }
    }
    return hits
}

let args = CommandLine.arguments
let configFile = configPath(from: args)
let loaded: KeypipeConfig
do {
    loaded = try loadConfig(path: configFile)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}

// TriggerMatcher is wired here for every mode. The live keystroke source
// on macOS is the CGEventTap hook (MacKeyTap.swift); on Linux and in dev
// the input arrives via --feed-stdin or --smoke-feed below.
var matcher = TriggerMatcher(rules: loaded.rules.map { TriggerRule($0) })

if let seed = smokeFeed(from: args) {
    let hits = feedAndRun(seed, matcher: &matcher, logPath: loaded.logPath)
    print("keypipe smoke-feed hits \(hits)")
    fflush(stdout)
    exit(hits > 0 ? 0 : 2)
}

if args.contains("--feed-stdin") {
    print("keypipe started with \(loaded.rules.count) rule(s) from \(configFile)")
    fflush(stdout)
    while let line = readLine(strippingNewline: false) {
        _ = feedAndRun(line, matcher: &matcher, logPath: loaded.logPath)
    }
    exit(0)
}

signal(SIGINT, handleSignal)
signal(SIGTERM, handleSignal)

print("keypipe started with \(loaded.rules.count) rule(s) from \(configFile)")
fflush(stdout)
while keepRunning {
    Thread.sleep(forTimeInterval: 0.1)
}
