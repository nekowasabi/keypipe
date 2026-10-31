import XCTest

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

@testable import keypipe

final class ShellTests: XCTestCase {
    func testExitAndOneTrailingNewline() {
        XCTAssertEqual(runShell("exit 3", input: "", env: [:], timeout: 2), .exited(3, stdout: ""))
        for (script, expected) in [
            ("printf 'ab\\n'", "ab"), ("printf 'ab\\n\\n'", "ab\n"), ("printf ab", "ab"),
        ] {
            XCTAssertEqual(runShell(script, input: "", env: [:], timeout: 2), .exited(0, stdout: expected))
        }
    }

    func testInputIsDataOnAllThreeChannels() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let input = "$(touch \(path)) `touch \(path)` \"dq\" 'sq'; こんにちは\nend"
        for script in ["printf %s \"$1\"", "printf %s \"$KEYPIPE_INPUT\"", "cat"] {
            XCTAssertEqual(runShell(script, input: input, env: [:], timeout: 2), .exited(0, stdout: input))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testTimeoutKillsTheProcessGroup() throws {
        for prefix in ["", "trap '' TERM; "] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let outcome = runShell(prefix + "sleep 30 & echo $! > \"$1\"; wait", input: path, env: [:], timeout: 0.15)
            XCTAssertEqual(outcome, .timedOut(seconds: 0))
            let child = try String(contentsOfFile: path).trimmingCharacters(in: .whitespacesAndNewlines)
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

    func testPipesAreDrainedWhileInputIsWritten() {
        let input = String(repeating: "x", count: 70000)
        let script = "dd if=/dev/zero bs=100000 count=2 2>/dev/null; cat"
        let expected = String(repeating: "\0", count: 200000) + input
        XCTAssertEqual(runShell(script, input: input, env: [:], timeout: 3), .exited(0, stdout: expected))
    }

    func testCallerWithClosedStandardDescriptorsStillWiresPipes() {
        let saved = dup(STDIN_FILENO)
        close(STDIN_FILENO)
        defer {
            dup2(saved, STDIN_FILENO)
            close(saved)
        }
        XCTAssertEqual(runShell("cat", input: "hello", env: [:], timeout: 2), .exited(0, stdout: "hello"))
    }

    func testClosedStdinDoesNotKillCaller() {
        let input = String(repeating: "x", count: 70000)
        XCTAssertEqual(runShell("exit 0", input: input, env: [:], timeout: 2), .exited(0, stdout: ""))
    }
}
