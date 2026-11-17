import Foundation

#if canImport(Glibc)
    import Glibc
    private typealias SpawnActions = posix_spawn_file_actions_t
#else
    import Darwin
    private typealias SpawnActions = posix_spawn_file_actions_t?
#endif

enum ShellOutcome: Equatable {
    case exited(Int32, stdout: String, stderr: String = "")
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
        for fd in inputPipe { close(fd) }
        return .exited(1, stdout: "")
    }
    guard pipe(&errorPipe) == 0 else {
        for fd in inputPipe + outputPipe { close(fd) }
        return .exited(1, stdout: "")
    }
    // Why: if the caller's 0, 1 or 2 is closed, pipe() reuses that number and the
    // child's dup2/close sequence below would close the descriptor it just set up.
    func above2(_ fd: Int32) -> Int32 {
        guard fd <= 2 else { return fd }
        let moved = fcntl(fd, F_DUPFD, 3)
        close(fd)
        return moved
    }
    inputPipe = inputPipe.map(above2)
    outputPipe = outputPipe.map(above2)
    errorPipe = errorPipe.map(above2)
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
    // Why: shell/selection-prompt.sh calls back into this binary, which need not be on PATH. A
    // caller's own value wins, so a check can stub the call out.
    if environment["KEYPIPE_BIN"] == nil {
        environment["KEYPIPE_BIN"] = Bundle.main.executablePath ?? CommandLine.arguments[0]
    }
    // Why: an app launched from Finder (voice-switch) has no locale, and then pbpaste prints
    // Japanese as MacJapanese bytes and pbcopy drops UTF-8 input, so osascript loses the prompt.
    if ["LC_ALL", "LC_CTYPE", "LANG"].allSatisfy({ environment[$0, default: ""].isEmpty }) {
        environment["LC_CTYPE"] = "UTF-8"
    }
    // Typed: with Glibc the literal is otherwise inferred as an array of C pointers and does not compile.
    let argv: [String] = ["/bin/sh", "-c", script, "keypipe", input]
    let arguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    let variables: [UnsafeMutablePointer<CChar>?] =
        environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        for pointer in arguments { free(pointer) }
        for pointer in variables { free(pointer) }
    }
    var pid: pid_t = 0
    configure(&actions)
    let launched = posix_spawn(&pid, "/bin/sh", &actions, &attributes, arguments, variables)
    guard launched == 0 else {
        for fd in descriptors { close(fd) }
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
                    write(
                        writer, $0.baseAddress!.advanced(by: offset),
                        min(16384, bytes.count - offset))
                }
                if count > 0 {
                    offset += count
                } else if count < 0 && errno != EAGAIN && errno != EINTR {
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
    return .exited(
        code, stdout: String(decoding: output, as: UTF8.self),
        stderr: String(decoding: errors, as: UTF8.self))
}

/// The non-empty values of `names`: the process's own, then ~/.zshenv for the rest. A name left
/// out was not found. `env` is merged into the lookup shell's environment (a test sets HOME).
func lookupEnvironment(_ names: [String], env: [String: String] = [:]) -> [String: String] {
    var found = ProcessInfo.processInfo.environment.filter {
        names.contains($0.key) && !$0.value.isEmpty
    }
    let missing = names.filter { found[$0] == nil }
    guard !missing.isEmpty else { return found }
    // ponytail: zsh -c reads only ~/.zshenv, so a variable exported only in .zshrc, .zprofile or
    // another shell's startup is not found; use zsh -lic or a keypipe env file if that is needed.
    // The names are config-checked identifiers, safe to splice.
    let script =
        #"/bin/zsh -c 'for n; do printf "%s\0" "${(P)n}"; done' zsh "#
        + missing.joined(separator: " ")
    guard case .exited(0, let stdout, _) = runShell(script, input: "", env: env, timeout: 5)
    else { return found }
    let values = stdout.split(separator: "\0", omittingEmptySubsequences: false)
    for (name, value) in zip(missing, values) where !value.isEmpty { found[name] = String(value) }
    return found
}

/// A macOS notification, the one notifier the daemon, the bridge and background jobs share.
func notifyUser(_ text: String) {
    // Why: the text rides in argv, never in the AppleScript source (R8).
    let script =
        "osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title \"keypipe\"' -e 'end run' \"$1\""
    _ = runShell(script, input: text, env: [:], timeout: 5)
}

/// Starts `path args` in its own session with `stdin` as its standard input and
/// /dev/null for output, and returns without waiting. false if it did not start.
/// `descriptors` is where Linux lists the open descriptors to close (a parameter only so a test can
/// make the listing fail).
func spawnDetached(
    _ path: String, _ args: [String], stdin payload: Data,
    descriptors: String = "/proc/self/fd"
) -> Bool {
    signal(SIGPIPE, SIG_IGN)
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return false }
    #if canImport(Glibc)
        var actions = SpawnActions()
        var attributes = posix_spawnattr_t()
        // Why: glibc defines POSIX_SPAWN_SETSID (0x80) only under _GNU_SOURCE, which Swift's Glibc module does not import.
        let flags: Int32 = 0x80
    #else
        var actions: SpawnActions = nil
        var attributes: posix_spawnattr_t?
        // Why: inheriting nothing else matters most for the bridge; a stdout pipe held
        // by the job would keep the widget's $(...) open until the webhook finished.
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
    #endif
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Why: its own session, so the HUP of a closed terminal or a killed tmux pane misses it.
    posix_spawnattr_setflags(&attributes, Int16(flags))
    posix_spawn_file_actions_adddup2(&actions, fds[0], STDIN_FILENO)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addclose(&actions, fds[1])
    #if canImport(Glibc)
        // Why: glibc has no POSIX_SPAWN_CLOEXEC_DEFAULT, so close what the job would inherit instead.
        // The open descriptors are listed, not scanned up to a bound, so a high number is not missed.
        // After the dup2 above, so fds[0] is already stdin; fds[1] has its own close.
        // ponytail: a descriptor another thread opens between this listing and the spawn still leaks;
        // nothing on Linux runs such a thread (no daemon), so closefrom is not worth an extra glibc floor.
        // Without the listing (no /proc, a chroot) the job would inherit everything, so it does not start.
        guard let open = try? FileManager.default.contentsOfDirectory(atPath: descriptors) else {
            close(fds[0])
            close(fds[1])
            return false
        }
        for fd in open.compactMap({ Int32($0) })
        where fd > 2 && fd != fds[1] && fcntl(fd, F_GETFD) != -1 {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
    #endif
    let arguments: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
    defer { for pointer in arguments { free(pointer) } }
    var pid: pid_t = 0
    let launched = posix_spawn(&pid, path, &actions, &attributes, arguments, environ)
    close(fds[0])
    guard launched == 0 else {
        close(fds[1])
        return false
    }
    payload.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = write(
                fds[1], buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count > 0 { offset += count } else if errno != EINTR { break }
        }
    }
    close(fds[1])
    // Why: the daemon lives on; an unreaped job would stay a zombie. SIGCHLD stays
    // default because runShell needs waitpid's status.
    Thread.detachNewThread {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
    return true
}
