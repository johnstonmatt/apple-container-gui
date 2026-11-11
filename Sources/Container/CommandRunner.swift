import Foundation
import AppKit
import Darwin

struct CommandOutput: Sendable {
    var stdout = ""
    var stderr = ""
    var exitCode: Int32 = 0
    var display: String {
        stdout + (stderr.isEmpty ? "" : "\n— stderr —\n" + stderr)
    }
}

@MainActor
enum CommandRunner {
    /// File-backed output avoids pipe deadlocks; only a bounded tail is kept in memory.
    static func run(executable: String, arguments: [String], directory: String? = nil,
                    input: String? = nil, timeout: TimeInterval = 600,
                    onOutput: ((CommandOutput) -> Void)? = nil) async throws -> CommandOutput {
        try Task.checkCancellation()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let stdoutURL = temp.appendingPathComponent("stdout")
        let stderrURL = temp.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: stdoutURL), err = try FileHandle(forWritingTo: stderrURL)
        let outReader = try FileHandle(forReadingFrom: stdoutURL), errReader = try FileHandle(forReadingFrom: stderrURL)
        defer { for handle in [out, err, outReader, errReader] { try? handle.close() } }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        process.environment = environment
        process.standardOutput = out
        process.standardError = err
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
        guard (input?.utf8.count ?? 0) <= 4096 else { throw CLIError(message: "Standard input exceeds 4 KB; use Terminal for larger input.") }
        try process.run()
        let started = Date()
        var output = CommandOutput()
        var stdout = Data(), stderr = Data()
        func collect() throws {
            stdout.append(try outReader.readToEnd() ?? Data())
            stderr.append(try errReader.readToEnd() ?? Data())
            // Keep recent output visible even for indefinitely streaming commands.
            let limit = 2 * 1024 * 1024
            if stdout.count > limit { stdout = Data(stdout.suffix(limit)) }
            if stderr.count > limit { stderr = Data(stderr.suffix(limit)) }
            output.stdout = String(decoding: stdout, as: UTF8.self)
            output.stderr = String(decoding: stderr, as: UTF8.self)
            onOutput?(output)
        }
        do {
            if let input {
                try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try stdin.fileHandleForWriting.close()
            }
            while process.isRunning {
                try Task.checkCancellation()
                if timeout > 0 && Date().timeIntervalSince(started) > timeout {
                    throw CLIError(message: "The command timed out. Refresh to check whether the operation completed.")
                }
                try collect()
                try await Task.sleep(for: .milliseconds(100))
            }
            process.waitUntilExit()
            try collect()
            output.exitCode = process.terminationStatus
            return output
        } catch {
            if process.isRunning {
                process.terminate()
                // This grace period must also work when the calling task is cancelled.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { continuation.resume() }
                }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
    }
}

@MainActor @Observable
final class OperationSession {
    enum Phase: Equatable {
        case idle, running, succeeded, cancelled, openedInTerminal
        case failed(exitCode: Int32?)
    }

    var output = ""
    var phase = Phase.idle
    private(set) var running = false
    private var task: Task<Void, Never>?

    var status: String {
        switch phase {
        case .idle: "Ready"
        case .running: "Running"
        case .succeeded: "Completed"
        case .failed(let code?): "Failed (exit \(code))"
        case .failed(nil): "Failed"
        case .cancelled: "Cancelled — refresh to check the resource state"
        case .openedInTerminal: "Opened in Terminal — refresh after completion"
        }
    }

    func start(executable: String, arguments: [String], directory: String, input: String? = nil,
               onCompletion: @escaping @MainActor () async -> Void) {
        guard !running else { return }
        running = true
        output = ""
        phase = .running
        task = Task {
            defer { running = false; task = nil }
            do {
                let result = try await CommandRunner.run(executable: executable, arguments: arguments,
                    directory: directory, input: input, timeout: 0) { self.output = $0.display }
                phase = result.exitCode == 0 ? .succeeded : .failed(exitCode: result.exitCode)
            } catch is CancellationError {
                phase = .cancelled
            } catch { phase = .failed(exitCode: nil); output += "\n" + error.localizedDescription }
            await Task { await onCompletion() }.value
        }
    }

    func cancel() { task?.cancel() }

    func clear() {
        guard !running else { return }
        output = ""
        phase = .idle
    }
}

enum TerminalScript {
    static func contents(executable: String, arguments: [String], directory: String, administrator: Bool) -> String {
        let command = ([executable] + arguments).map(ArgumentWords.quote).joined(separator: " ")
        return """
        #!/bin/zsh
        /bin/rm -- "$0"
        cd -- \(ArgumentWords.quote(directory)) || exit 1
        \(administrator ? "/usr/bin/sudo -- " : "")\(command)
        operation_status=$?
        print -r -- "Command exited with status $operation_status"
        exit $operation_status
        """
    }

    @MainActor static func open(executable: String, arguments: [String], directory: String, administrator: Bool) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw CLIError(message: "Terminal.app could not be found.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Container-\(UUID().uuidString).command")
        try contents(executable: executable, arguments: arguments, directory: directory, administrator: administrator)
            .write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        do {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: .init())
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
}
