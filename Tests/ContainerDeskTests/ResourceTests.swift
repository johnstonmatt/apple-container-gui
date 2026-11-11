import XCTest
@testable import ContainerDesk

final class ResourceTests: XCTestCase {
    private func catalog() throws -> [CommandDefinition] { CommandCatalog.definitions(try CommandCatalog.bundledPages()) }
    private func command(_ path: [String]) throws -> CommandDefinition {
        try XCTUnwrap(catalog().first { $0.path == path }, path.joined(separator: " "))
    }
    private var allActions: [(ResourceKind, ResourceAction)] {
        ResourceKind.allCases.flatMap { kind in (kind.itemActions + kind.collectionActions).map { (kind, $0) } }
    }

    func testEveryCatalogCommandBelongsToAResourceAndNoneAreStale() throws {
        let ids = Set(try catalog().map(\.id))
        XCTAssertEqual(ids.subtracting(ResourceKind.coveredCommandIDs), [], "Commands without a resource")
        XCTAssertEqual(ResourceKind.coveredCommandIDs.subtracting(ids), [], "Resource commands missing from the CLI")
    }

    func testActionSubjectsAndPresetsReferToRealArgumentsAndOptions() throws {
        for (kind, action) in allActions {
            let definition = try command(action.path)
            let flags = Set(definition.options.map(\.flag))
            let names = Set(definition.arguments.map(\.name))
            switch action.subject {
            case .none: break
            case .argument(let name), .argumentPrefix(let name): XCTAssertTrue(names.contains(name), "\(kind) \(action.title): \(name)")
            case .option(let flag): XCTAssertTrue(flags.contains(flag), "\(kind) \(action.title): \(flag)")
            }
            for flag in action.options.keys { XCTAssertTrue(flags.contains(flag), "\(kind) \(action.title): \(flag)") }
            for name in action.arguments.keys { XCTAssertTrue(names.contains(name), "\(kind) \(action.title): \(name)") }
        }
    }

    func testImmediateItemActionsBuildCommandsForTheirResource() throws {
        for kind in ResourceKind.allCases {
            for action in kind.itemActions where action.behavior == .immediate {
                let definition = try command(action.path)
                let arguments = try action.draft(for: definition, subject: "web.test").arguments(for: definition)
                XCTAssertEqual(Array(arguments.prefix(action.path.count)), action.path)
                XCTAssertTrue(arguments.contains("web.test"), "\(kind) \(action.title): \(arguments)")
            }
        }
        let delete = try XCTUnwrap(ResourceKind.containers.itemActions.first { $0.path == ["delete"] })
        XCTAssertEqual(try delete.draft(for: command(["delete"]), subject: "web").arguments(for: command(["delete"])), ["delete", "web"])
        let cluster = try XCTUnwrap(ResourceKind.clusters.itemActions.first { $0.path == ["cluster", "delete"] })
        XCTAssertEqual(try cluster.draft(for: command(["cluster", "delete"]), subject: "dev").arguments(for: command(["cluster", "delete"])),
                       ["cluster", "delete", "--name", "dev"])
    }

    func testRepeatedArgumentSubjectsStayOneWord() throws {
        let delete = try XCTUnwrap(ResourceKind.images.itemActions.first { $0.path == ["image", "delete"] })
        let definition = try command(["image", "delete"])
        XCTAssertEqual(try delete.draft(for: definition, subject: "my image:1").arguments(for: definition), ["image", "delete", "my image:1"])
    }

    func testShellActionPrefillsAnInteractiveTerminalSession() throws {
        let shell = try XCTUnwrap(ResourceKind.containers.itemActions.first { $0.title == "Open Shell" })
        let definition = try command(["exec"])
        let draft = shell.draft(for: definition, subject: "web")
        XCTAssertTrue(draft.requiresTerminal(for: definition))
        let arguments = try draft.arguments(for: definition)
        XCTAssertTrue(arguments.contains("--interactive") && arguments.contains("--tty"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["web", "sh"])
    }

    func testCopyActionPrefixesTheContainerPath() throws {
        let copy = try XCTUnwrap(ResourceKind.containers.itemActions.first { $0.path == ["copy"] })
        XCTAssertEqual(copy.draft(for: try command(["copy"]), subject: "web").positionals["source"], "web:")
    }

    func testAvailabilityFollowsRunningState() throws {
        let running = ResourceItem(id: "web", record: .object(["status": .object(["state": .string("running")])]))
        let stopped = ResourceItem(id: "web", record: .object(["status": .string("stopped")]))
        let titles = { (item: ResourceItem) in ResourceKind.containers.itemActions.filter { $0.available(for: item) }.map(\.title) }
        XCTAssertTrue(titles(running).contains("Stop"))
        XCTAssertFalse(titles(running).contains("Start"))
        XCTAssertFalse(titles(running).contains("Delete"))
        XCTAssertTrue(titles(stopped).contains("Start"))
        XCTAssertTrue(titles(stopped).contains("Delete"))
        XCTAssertFalse(titles(stopped).contains("Open Shell"))
    }

    func testDecodesListOutputIntoItemsAndFields() throws {
        let networks = """
        [{"configuration":{"mode":"nat","name":"default"},"id":"default","status":{"ipv4Gateway":"192.168.64.1","ipv4Subnet":"192.168.64.0/24"}}]
        """
        let network = try XCTUnwrap(ResourceKind.networks.items(fromJSON: networks)?.first)
        XCTAssertEqual(network.id, "default")
        XCTAssertNil(network.state)
        XCTAssertEqual(ResourceKind.networks.fields.compactMap(network.value), ["192.168.64.0/24", "192.168.64.1"])

        let images = #"[{"configuration":{"name":"docker.io/library/alpine:latest"},"id":"sha256:f59a"}]"#
        XCTAssertEqual(try ResourceKind.images.items(fromJSON: images)?.map(\.id), ["docker.io/library/alpine:latest"])

        let containers = """
        [{"configuration":{"id":"web","resources":{"cpus":4,"memoryInBytes":1073741824}},"id":"web",
          "status":{"state":"running","networks":[{"ipv4Address":"192.168.64.5/24"}]}}]
        """
        let container = try XCTUnwrap(ResourceKind.containers.items(fromJSON: containers)?.first)
        XCTAssertTrue(container.running)
        XCTAssertEqual(ResourceKind.containers.fields.compactMap(container.value), ["192.168.64.5/24", "4", "1 GB"])
    }

    func testUnknownSchemasFallBackToQuietIdentifiers() throws {
        XCTAssertNil(try ResourceKind.registries.items(fromJSON: #"[{"unexpected":"shape"}]"#))
        XCTAssertEqual(try ResourceKind.builder.items(fromJSON: "[]"), [])
        XCTAssertEqual(ResourceKind.items(fromQuiet: "ghcr.io\n\n docker.io \n").map(\.id), ["ghcr.io", "docker.io"])
    }

    func testJSONValuePathsLeavesAndText() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"a":{"b":[{"c":1.5},{"c":true}],"tags":["x","y"]},"n":3,"empty":""}
        """.utf8))
        XCTAssertEqual(value["a.b.1.c"]?.text, "Yes")
        XCTAssertEqual(value["a.b.0.c"]?.text, "1.5")
        XCTAssertEqual(value["a.tags"]?.text, "x, y")
        XCTAssertEqual(value["n"]?.text, "3")
        XCTAssertNil(value["empty"]?.text)
        XCTAssertNil(value["a.missing.path"])
        XCTAssertEqual(value.leaves().map { $0.path.joined(separator: ".") }, ["a.b.1.c", "a.b.2.c", "a.tags", "n"])
    }

    func testOverviewLabelsReadNaturally() {
        XCTAssertEqual(RecordOverview.humanize("ipv4Address"), "IPv4 address")
        XCTAssertEqual(RecordOverview.humanize("memoryInBytes"), "Memory")
        XCTAssertEqual(RecordOverview.humanize("cpus"), "CPUs")
        XCTAssertEqual(RecordOverview.humanize("id"), "ID")
        XCTAssertEqual(RecordOverview.humanize("com.apple.container.resource.role"), "com.apple.container.resource.role")
    }

    func testQuickRunCarriesItsSettingsIntoTheFullRunForm() throws {
        let config = RunConfiguration(image: "nginx:latest", name: "web", port: "8080:80", cpus: 3, memory: 2048)
        let full = try config.draft.arguments(for: command(["run"]))
        XCTAssertEqual(full.first, "run")
        XCTAssertEqual(full.last, "nginx:latest")
        XCTAssertEqual(Set(full), Set(config.arguments))
    }
}
