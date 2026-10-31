import Foundation

/// Executes the configured action for a matched trigger rule.
public func runAction(_ action: Action) -> Int32 {
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
    default:
        fputs("keypipe: unknown action type: \(action.type)\n", stderr)
        return 1
    }
}
