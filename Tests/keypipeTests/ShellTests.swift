import XCTest

@testable import keypipe

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

final class ShellTests: XCTestCase {
    func testExitAndOneTrailingNewline() {
        XCTAssertEqual(runShell("exit 3", input: "", env: [:], timeout: 2), .exited(3, stdout: ""))
        for (script, expected) in [
            ("printf 'ab\\n'", "ab"), ("printf 'ab\\n\\n'", "ab\n"), ("printf ab", "ab"),
        ] {
            XCTAssertEqual(
                runShell(script, input: "", env: [:], timeout: 2), .exited(0, stdout: expected))
        }
    }

    func testInputIsDataOnAllThreeChannels() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .path
        let input = "$(touch \(path)) `touch \(path)` \"dq\" 'sq'; こんにちは\nend"
        for script in ["printf %s \"$1\"", "printf %s \"$KEYPIPE_INPUT\"", "cat"] {
            XCTAssertEqual(
                runShell(script, input: input, env: [:], timeout: 2), .exited(0, stdout: input))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testTimeoutKillsTheProcessGroup() throws {
        for prefix in ["", "trap '' TERM; "] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString
            ).path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let outcome = runShell(
                prefix + "sleep 30 & echo $! > \"$1\"; wait", input: path, env: [:], timeout: 0.15)
            XCTAssertEqual(outcome, .timedOut(seconds: 0))
            let child = try String(contentsOfFile: path).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let pid = try XCTUnwrap(Int32(child))
            // Why: SIGKILL delivery and orphan reaping are asynchronous after the deadline.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.35
            while kill(pid, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            XCTAssertNotEqual(kill(pid, 0), 0)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    /// A background job leads its own session (a closed terminal's HUP misses it) and does not inherit
    /// the descriptors its parent holds open, low or high numbered. Descriptor 0 is probed too, so a
    /// probe that sees nothing cannot pass.
    func testDetachedJobHasItsOwnSessionAndNoInheritedDescriptors() throws {
        var held: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&held), 0)
        // Well above the usual numbers: a scan up to 65536 once missed fd 70000 on Linux. R1d raises the
        // limit so that number is usable there; otherwise 200 stays under macOS's 256 soft limit.
        let floor: Int32 = getdtablesize() > 70_001 ? 70_000 : 200
        let high = fcntl(held[0], F_DUPFD, floor)
        XCTAssertGreaterThanOrEqual(high, floor)
        held.append(high)
        defer { held.forEach { close($0) } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // An external test checks each descriptor with no redirection active: a shell builtin would also
        // see the descriptors the shell saves while redirecting, and ls its own directory handle.
        let script =
            "echo $$ > \"$0/pid\"; : > \"$0/fds.tmp\"; for fd; do if /usr/bin/env test -e \"/dev/fd/$fd\"; then echo \"$fd\" >> \"$0/fds.tmp\"; fi; done; mv \"$0/fds.tmp\" \"$0/fds\"; sleep 2"
        XCTAssertTrue(
            spawnDetached(
                "/bin/sh", ["-c", script, dir, "0"] + held.map(String.init), stdin: Data()))
        var pid: pid_t = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let text = try? String(contentsOfFile: dir + "/pid"),
                let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                FileManager.default.fileExists(atPath: dir + "/fds")
            {
                pid = value
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Why: kill(0, ...) would hit the whole test runner's process group.
        guard pid > 0 else { return XCTFail("the job did not start") }
        defer { kill(pid, SIGKILL) }
        XCTAssertEqual(getsid(pid), pid, "the job leads its own session")
        XCTAssertNotEqual(getsid(pid), getsid(0))
        let open = try String(contentsOfFile: dir + "/fds").split(separator: "\n").compactMap {
            Int32($0)
        }
        XCTAssertEqual(open, [0], "stdin is open and nothing of \(held) is inherited")
    }

    /// Linux closes the job's inherited descriptors from a listing; without one the job must not start.
    func testDetachedJobDoesNotStartWhenDescriptorsCannotBeListed() throws {
        #if canImport(Glibc)
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString
            ).path
            defer { try? FileManager.default.removeItem(atPath: marker) }
            XCTAssertFalse(
                spawnDetached(
                    "/bin/sh", ["-c", ": > \"$0\"", marker], stdin: Data(),
                    descriptors: "/nonexistent/fd"))
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: marker),
                "the job ran without its descriptors closed")
        #else
            throw XCTSkip("macOS closes them with POSIX_SPAWN_CLOEXEC_DEFAULT")
        #endif
    }

    func testPipesAreDrainedWhileInputIsWritten() {
        let input = String(repeating: "x", count: 70000)
        let script = "dd if=/dev/zero bs=100000 count=2 2>/dev/null; cat"
        let expected = String(repeating: "\0", count: 200000) + input
        XCTAssertEqual(
            runShell(script, input: input, env: [:], timeout: 3), .exited(0, stdout: expected))
    }

    func testCallerWithClosedStandardDescriptorsStillWiresPipes() {
        let saved = dup(STDIN_FILENO)
        close(STDIN_FILENO)
        defer {
            dup2(saved, STDIN_FILENO)
            close(saved)
        }
        XCTAssertEqual(
            runShell("cat", input: "hello", env: [:], timeout: 2), .exited(0, stdout: "hello"))
    }

    func testClosedStdinDoesNotKillCaller() {
        let input = String(repeating: "x", count: 70000)
        XCTAssertEqual(
            runShell("exit 0", input: input, env: [:], timeout: 2), .exited(0, stdout: ""))
    }
}
