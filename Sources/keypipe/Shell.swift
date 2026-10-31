import Foundation

#if canImport(Glibc)
    import Glibc
    private typealias SpawnActions = posix_spawn_file_actions_t
#else
    import Darwin
    private typealias SpawnActions = posix_spawn_file_actions_t?
#endif

enum ShellOutcome: Equatable {
    case exited(Int32, stdout: String)
    case timedOut(seconds: Int)
}

func runShell(_ script: String, input: String, env: [String: String], timeout: TimeInterval)
    -> ShellOutcome
{
    signal(SIGPIPE, SIG_IGN)
    var inputPipe: [Int32] = [0, 0]
    var outputPipe: [Int32] = [0, 0]
    var errorPipe: [Int32] = [0, 0]
    guard pipe(&inputPipe) == 0 else { return .exited(1, stdout: "") }
    guard pipe(&outputPipe) == 0 else {
        inputPipe.forEach { close($0) }
        return .exited(1, stdout: "")
    }
    guard pipe(&errorPipe) == 0 else {
        (inputPipe + outputPipe).forEach { close($0) }
        return .exited(1, stdout: "")
    }
    let descriptors = inputPipe + outputPipe + errorPipe
    for fd in descriptors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

    #if canImport(Glibc)
        var actions = SpawnActions()
        var attributes = posix_spawnattr_t()
    #else
        var actions: SpawnActions = nil
        var attributes: posix_spawnattr_t?
    #endif
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)

    func configure(_ actions: UnsafeMutablePointer<SpawnActions>) {
        posix_spawn_file_actions_adddup2(actions, inputPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(actions, errorPipe[1], STDERR_FILENO)
        for fd in descriptors { posix_spawn_file_actions_addclose(actions, fd) }
    }
    var environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
    environment["KEYPIPE_INPUT"] = input
    let arguments = ["/bin/sh", "-c", script, "keypipe", input].map { strdup($0) } + [nil]
    let variables = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        arguments.forEach { free($0) }
        variables.forEach { free($0) }
    }
    var pid: pid_t = 0
    configure(&actions)
    let launched = posix_spawn(&pid, "/bin/sh", &actions, &attributes, arguments, variables)
    guard launched == 0 else {
        descriptors.forEach { close($0) }
        return .exited(1, stdout: "")
    }
    close(inputPipe[0])
    close(outputPipe[1])
    close(errorPipe[1])
    var writer = inputPipe[1]
    var reader = outputPipe[0]
    var errorReader = errorPipe[0]
    for fd in [writer, reader, errorReader] {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }
    defer {
        for fd in [writer, reader, errorReader] where fd >= 0 { close(fd) }
    }
    let bytes = Array(input.utf8)
    var offset = 0
    var output = Data()
    var errors = Data()
    var status: Int32 = 0
    var reaped = false
    var timedOut = false
    let deadline = ProcessInfo.processInfo.systemUptime + timeout

    func readChunk(_ fd: inout Int32, into data: inout Data) {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16384)
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            data.append(contentsOf: buffer.prefix(count))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            close(fd)
            fd = -1
        }
    }

    // Why: Multiplex all three pipes so a full stdout cannot block stdin delivery.
    while true {
        if !reaped { reaped = waitpid(pid, &status, WNOHANG) == pid }
        readChunk(&reader, into: &output)
        readChunk(&errorReader, into: &errors)
        if writer >= 0 {
            if offset < bytes.count {
                let count = bytes.withUnsafeBytes {
                    write(writer, $0.baseAddress!.advanced(by: offset), min(16384, bytes.count - offset))
                }
                if count > 0 { offset += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR {
                    close(writer)
                    writer = -1
                }
            }
            if writer >= 0 && offset == bytes.count {
                close(writer)
                writer = -1
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if !timedOut && now >= deadline {
            timedOut = true
            kill(-pid, SIGTERM)
        }
        if timedOut && now >= deadline + 1 {
            kill(-pid, SIGKILL)
            break
        }
        if !timedOut && reaped && reader < 0 && errorReader < 0 { break }
        var polls = [
            pollfd(fd: reader, events: Int16(POLLIN), revents: 0),
            pollfd(fd: errorReader, events: Int16(POLLIN), revents: 0),
            pollfd(fd: writer, events: Int16(POLLOUT), revents: 0),
        ]
        _ = poll(&polls, nfds_t(polls.count), 10)
    }
    if !reaped { while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
    if !errors.isEmpty { FileHandle.standardError.write(errors) }
    if timedOut { return .timedOut(seconds: Int(timeout)) }
    if output.last == 10 { output.removeLast() }
    let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    return .exited(code, stdout: String(decoding: output, as: UTF8.self))
}
