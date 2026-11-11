import XCTest
@testable import ContainerDesk

@MainActor
final class RunnerTests: XCTestCase {
    func testCapturesBothStreamsAndExitStatus() async throws {
        let result = try await CommandRunner.run(executable: "/bin/zsh", arguments: ["-c", "print -r -- output; print -u2 -r -- failure; exit 7"])
        XCTAssertEqual(result.stdout, "output\n")
        XCTAssertEqual(result.stderr, "failure\n")
        XCTAssertEqual(result.exitCode, 7)
    }

    func testArgumentsStayLiteralAndWorkingDirectoryIsApplied() async throws {
        let payload = "$(touch /tmp/never-created); 'quoted' $HOME"
        let result = try await CommandRunner.run(executable: "/bin/zsh", arguments: ["-c", "print -r -- \"$1\"; pwd", "test", payload], directory: "/private/tmp")
        XCTAssertEqual(result.stdout, payload + "\n/private/tmp\n")
    }

    func testStdinDeliveredWithoutArgumentExposure() async throws {
        let result = try await CommandRunner.run(executable: "/bin/zsh", arguments: ["-c", "read -r token; print -r -- \"${#token}\""], input: "my-secret\n")
        XCTAssertEqual(result.stdout, "9\n")
        XCTAssertFalse(result.display.contains("my-secret"))
    }

    func testStreamingArrivesBeforeExit() async throws {
        var observed = false
        let result = try await CommandRunner.run(executable: "/bin/zsh", arguments: ["-c", "print first; sleep 0.3; print last"]) { output in
            if output.stdout.contains("first") && !output.stdout.contains("last") { observed = true }
        }
        XCTAssertTrue(observed)
        XCTAssertEqual(result.stdout, "first\nlast\n")
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        let result = try await CommandRunner.run(executable: "/bin/zsh", arguments: ["-c", "repeat 10000 print -r -- 012345678901234567890123456789; print -u2 done"], timeout: 10)
        XCTAssertGreaterThan(result.stdout.count, 250_000)
        XCTAssertEqual(result.stderr, "done\n")
    }

    func testTimeoutTerminatesProcess() async throws {
        let began = Date()
        do {
            _ = try await CommandRunner.run(executable: "/bin/zsh", arguments: ["-c", "exec sleep 20"], timeout: 0.15)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    }

    func testCancellationTerminatesProcess() async throws {
        let task = Task { try await CommandRunner.run(executable: "/bin/zsh", arguments: ["-c", "exec sleep 20"]) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLaunchFailureIsReported() async {
        do { _ = try await CommandRunner.run(executable: "/not/a/real/executable", arguments: []); XCTFail("Expected launch failure") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testOperationSessionReportsExitStatusAndClears() async throws {
        let session = OperationSession()
        var completed = false
        session.start(executable: "/bin/zsh", arguments: ["-c", "print -r -- done; exit 3"], directory: "/private/tmp") { completed = true }
        XCTAssertEqual(session.phase, .running)
        while session.running { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(completed)
        XCTAssertEqual(session.phase, .failed(exitCode: 3))
        XCTAssertEqual(session.status, "Failed (exit 3)")
        XCTAssertEqual(session.output, "done\n")
        session.clear()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.output, "")
    }

    func testTerminalScriptQuotesAllInputsAndUsesZsh() async throws {
        let script = TerminalScript.contents(executable: "/bin/echo", arguments: ["it's literal", "$(id)", "; exit 9"], directory: "/private/tmp", administrator: false)
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"))
        XCTAssertFalse(script.contains("sudo"))
        // Substitute only the script's self-removal line so this test never deletes its caller.
        let testScript = script.replacingOccurrences(of: "/bin/rm -- \"$0\"", with: ":")
        let result = try await CommandRunner.run(executable: "/bin/zsh", arguments: ["-c", testScript])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("it's literal $(id) ; exit 9"))
    }
}
