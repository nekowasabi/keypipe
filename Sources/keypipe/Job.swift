import Foundation

#if canImport(Glibc)
    import Glibc
#endif

/// What a background fire sends to `keypipe --job` on stdin. The input never rides in argv.
/// `config` is the path, kept for the jobs.log line. `configBytes` is what the parent parsed;
/// the child parses those bytes, not the file, so `job.rule` indexes the rules the parent
/// matched even if the file was edited since.
struct JobRequest: Codable {
    var config: String
    var configBytes: Data
    var job: Job
}

/// Re-executes this binary as a detached `--job`. Returns false, and reports through `emit`,
/// when it cannot start.
func startJob(_ job: Job, configPath: String, configBytes: Data, emit: (String) -> Void) -> Bool {
    let request = JobRequest(
        config: URL(fileURLWithPath: configPath).path, configBytes: configBytes, job: job)
    guard let executable = Bundle.main.executablePath,
        let payload = try? JSONEncoder().encode(request),
        spawnDetached(executable, ["--job"], stdin: payload)
    else {
        emit("keypipe background-failed spawn")
        notifyUser("keypipe: background job did not start")
        return false
    }
    return true
}

/// ${XDG_STATE_HOME:-~/.local/state}/keypipe/jobs.log
func jobsLogPath() -> String {
    let base =
        ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        ?? NSString(string: "~/.local/state").expandingTildeInPath
    return base + "/keypipe/jobs.log"
}

/// Shell runner for a job: every stage gets at most what is left of `limit`, and a stage
/// cut short by that reports the job's limit, so the transcript names the knob to raise.
func boundedShell(
    limit: TimeInterval,
    run: @escaping (String, String, [String: String], TimeInterval) -> ShellOutcome
)
    -> (String, String, [String: String], TimeInterval) -> ShellOutcome
{
    let deadline = ProcessInfo.processInfo.systemUptime + limit
    return { script, input, env, timeout in
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        guard remaining < timeout else { return run(script, input, env, timeout) }
        let outcome = run(script, input, env, remaining)
        if case .timedOut = outcome { return .timedOut(seconds: Int(limit)) }
        return outcome
    }
}

/// `keypipe --job`: runs one background fire to completion and logs it to jobs.log.
func runJobProcess() -> Never {
    let path = jobsLogPath()
    try? FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
    let log = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    let pid = getpid()
    // Why: one write per line with O_APPEND keeps concurrent jobs' lines whole.
    let emit: (String) -> Void = { line in
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(pid) \(line)\n"
        _ = stamped.withCString { write(log, $0, strlen($0)) }
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let request: JobRequest
    let config: KeypipeConfig
    do {
        request = try JSONDecoder().decode(JobRequest.self, from: data)
        config = try loadConfig(data: request.configBytes)
    } catch {
        emit("keypipe job-failed \(jsonString("\(error)"))")
        notifyUser("keypipe: background job failed: \(error)")
        exit(1)
    }
    emit("keypipe job rule \(request.job.rule) from \(request.config)")
    let engine = Engine(
        config: config,
        desktop: LineDesktop(app: request.job.environment["KEYPIPE_APP"], line: nil),
        shell: boundedShell(limit: config.backgroundTimeout, run: runShell), emit: emit,
        lookupEnv: { lookupEnvironment($0) })
    engine.run(request.job)
    emit("keypipe job done")
    exit(0)
}
