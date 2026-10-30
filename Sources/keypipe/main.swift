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

let configFile = configPath(from: CommandLine.arguments)
let loaded: KeypipeConfig
do {
    loaded = try loadConfig(path: configFile)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}

signal(SIGINT, handleSignal)
signal(SIGTERM, handleSignal)

print("keypipe started with \(loaded.rules.count) rule(s) from \(configFile)")
fflush(stdout)
while keepRunning {
    Thread.sleep(forTimeInterval: 0.1)
}
