import XCTest
@testable import ContainerDesk

/// Opt in with RUN_CONTAINER_INTEGRATION_TESTS=1. Never touches existing containers.
@MainActor
final class LiveCLITests: XCTestCase {
    private func requireRuntime() throws {
        guard ProcessInfo.processInfo.environment["RUN_CONTAINER_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_CONTAINER_INTEGRATION_TESTS=1 to test the installed CLI and runtime.")
        }
        XCTAssertNotNil(ContainerCLI.executable)
    }

    func testInstalledCommandTreeMatchesBundledCoverage() async throws {
        try requireRuntime()
        let live = try await CommandCatalog.discover(using: ContainerCLI())
        let liveDefinitions = CommandCatalog.definitions(live)
        let bundled = try CommandCatalog.definitions(CommandCatalog.bundledPages())
        XCTAssertEqual(Set(liveDefinitions.map(\.id)), Set(bundled.map(\.id)))
        for command in liveDefinitions {
            let reference = try XCTUnwrap(bundled.first { $0.id == command.id })
            XCTAssertEqual(command.options.map(\.flag), reference.options.map(\.flag), command.id)
            XCTAssertEqual(command.arguments.map(\.name), reference.arguments.map(\.name), command.id)
        }
    }

    func testReadOnlyInventories() async throws {
        try requireRuntime()
        let cli = ContainerCLI()
        for path in [["list", "--all"], ["image", "list"], ["network", "list"], ["volume", "list"], ["machine", "list"], ["registry", "list"]] {
            let result = try await cli.run(path + ["--format", "json"])
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(result.utf8)), path.joined(separator: " "))
        }
    }

    func testIsolatedContainerLifecycle() async throws {
        try requireRuntime()
        let cli = ContainerCLI()
        let name = "containerdesk-test-" + UUID().uuidString.lowercased().prefix(8)
        var created = false
        do {
            _ = try await cli.run(["run", "--detach", "--name", name, "alpine:latest", "sh", "-c", "echo containerdesk-ready; sleep 120"], timeout: 180)
            created = true
            let inventory = try await cli.run(["list", "--all", "--format", "json"])
            let records = try JSONDecoder().decode([ContainerRecord].self, from: Data(inventory.utf8))
            XCTAssertEqual(records.first { $0.id == name }?.running, true)
            let exec = try await cli.run(["exec", name, "printf", "%s", "literal $HOME; $(id)"])
            XCTAssertEqual(exec, "literal $HOME; $(id)")
            let logs = try await cli.run(["logs", "-n", "200", name])
            XCTAssertTrue(logs.contains("containerdesk-ready"))
            let inspect = try await cli.run(["inspect", name])
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(inspect.utf8)))
            _ = try await cli.run(["stats", "--no-stream", name])
            _ = try await cli.run(["stop", name])
            _ = try await cli.run(["start", name])
            _ = try await cli.run(["stop", name])
            _ = try await cli.run(["delete", name])
            created = false
        } catch {
            if created {
                _ = try? await cli.run(["stop", name])
                _ = try? await cli.run(["delete", name])
            }
            throw error
        }
    }
}
