import Foundation

/// Executes the configured action for a matched trigger rule.
/// shell runs command via /bin/sh -c. log appends message to logPath,
/// or prints it when logPath is nil.
public func runAction(_ action: Action, logPath: String?) -> Int32 {
    switch action.type {
    case "shell":
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", action.command ?? ""]
        do {
            try process.run()
        } catch {
            fputs("keypipe: action failed to launch: \(error)\n", stderr)
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    case "log":
        let line = (action.message ?? "") + "\n"
        guard let path = logPath, !path.isEmpty else {
            print("keypipe log: \(action.message ?? "")")
            fflush(stdout)
            return 0
        }
        guard let data = line.data(using: .utf8) else { return 1 }
        if FileManager.default.fileExists(atPath: path) {
            do {
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                fputs("keypipe: cannot write log: \(error)\n", stderr)
                return 1
            }
        } else {
            do {
                try data.write(to: URL(fileURLWithPath: path))
            } catch {
                fputs("keypipe: cannot write log: \(error)\n", stderr)
                return 1
            }
        }
        return 0
    default:
        fputs("keypipe: unknown action type: \(action.type)\n", stderr)
        return 1
    }
}
