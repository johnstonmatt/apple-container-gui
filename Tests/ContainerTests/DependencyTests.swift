import XCTest
@testable import Container

@MainActor
final class DependencyTests: XCTestCase {
    private func running(root: String = "/tmp/custom runtime", architecture: String = "arm64") throws -> CommandOutput {
        let json: [String: Any] = ["status": "running", "paths": ["appRoot": root], "host": ["architecture": architecture]]
        return CommandOutput(stdout: String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
    }

    func testMissingCLIDoesNotLaunchAnyCommand() async {
        var called = false
        let state = await DependencyChecker.check(executable: nil) {
            called = true
            return CommandOutput()
        }
        XCTAssertEqual(state, .missingCLI)
        XCTAssertFalse(called)
        XCTAssertNil(state.recoveryArguments)
    }

    func testStoppedServiceJSONWithNonzeroExitCodeIsRecognized() {
        for status in ["unregistered", "not running", "stopped"] {
            let output = CommandOutput(stdout: "{\"status\":\"\(status)\"}", exitCode: 1)
            XCTAssertEqual(DependencyChecker.evaluate(output) { _ in XCTFail("Should not inspect kernels yet"); return .present }, .serviceStopped)
        }
        XCTAssertEqual(DependencyState.serviceStopped.recoveryArguments, ["system", "start", "--enable-kernel-install"])
    }

    func testRunningServiceStillRequiresInstalledKernelAtReportedRoot() throws {
        let state = DependencyChecker.evaluate(try running()) { path in
            XCTAssertEqual(path.path, "/tmp/custom runtime/kernels/default.kernel-arm64")
            return .missing
        }
        XCTAssertEqual(state, .missingKernel(path: "/tmp/custom runtime/kernels/default.kernel-arm64"))
        XCTAssertEqual(state.recoveryTitle, "Install Linux Kernel")
        XCTAssertEqual(state.recoveryArguments, ["system", "kernel", "set", "--recommended", "--force"])
        XCTAssertEqual(DependencyChecker.evaluate(try running()) { _ in .present }, .ready)
    }

    func testUnknownAndFailedStatusNeverClaimsKernelIsMissing() throws {
        for output in [CommandOutput(stdout: "not json", stderr: "Permission denied", exitCode: 1),
                       CommandOutput(stdout: "{\"status\":\"running\"}"),
                       CommandOutput(stdout: "{\"status\":\"starting\"}"),
                       try running(root: "relative/path"), try running(architecture: "future-architecture")] {
            let state = DependencyChecker.evaluate(output)
            guard case .unavailable = state else { return XCTFail("Expected an unverifiable state, got \(state)") }
            XCTAssertNil(state.recoveryArguments)
        }
        let unreadable = DependencyChecker.evaluate(try running()) { _ in .unreadable("Permission denied") }
        XCTAssertEqual(unreadable, .unavailable("Permission denied"))
    }

    func testStatusLaunchFailuresRemainActionable() async {
        let state = await DependencyChecker.check(executable: "/test/container") {
            throw CLIError(message: "Timed out")
        }
        guard case .unavailable(let reason) = state else { return XCTFail("Expected unavailable") }
        XCTAssertTrue(reason.contains("Timed out"))
    }

    func testKernelFileSymlinkBrokenLinkAndEmptyFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kernel = root.appendingPathComponent("kernel")
        let link = root.appendingPathComponent("default.kernel-arm64")
        XCTAssertEqual(KernelPresence.inspect(link), .missing)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: kernel)
        XCTAssertEqual(KernelPresence.inspect(link), .missing)
        try Data().write(to: kernel)
        XCTAssertEqual(KernelPresence.inspect(link), .missing)
        try Data("kernel fixture".utf8).write(to: kernel)
        XCTAssertEqual(KernelPresence.inspect(link), .present)
        guard case .unreadable = KernelPresence.inspect(root) else { return XCTFail("Directories aren't kernels") }
    }

    func testRefreshGatesInventoryAndClearsStaleResources() async {
        let states: [DependencyState] = [.missingCLI, .serviceStopped, .missingKernel(path: "/missing"), .unavailable("Permission denied")]
        for state in states {
            let store = Store(checkDependencies: { state })
            store.connected = true
            store.inventories[.images] = [ResourceItem(id: "stale", record: .null)]
            store.inventoryErrors[.images] = "stale error"
            await store.refresh()
            XCTAssertFalse(store.connected)
            XCTAssertEqual(store.dependencies, state)
            XCTAssertTrue(store.inventories.isEmpty)
            XCTAssertTrue(store.inventoryErrors.isEmpty)
            XCTAssertFalse(store.refreshing)
        }
    }

    func testCheckAgainUpdatesTheDependencyState() async {
        var state = DependencyState.missingCLI
        let store = Store(checkDependencies: { state })
        await store.refresh()
        XCTAssertEqual(store.dependencies, .missingCLI)
        state = .serviceStopped
        await store.refresh()
        XCTAssertEqual(store.dependencies, .serviceStopped)
    }
}
