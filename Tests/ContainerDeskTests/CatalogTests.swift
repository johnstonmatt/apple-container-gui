import XCTest
@testable import ContainerDesk

final class CatalogTests: XCTestCase {
    private func command(_ id: String) throws -> CommandDefinition {
        try XCTUnwrap(CommandCatalog.definitions(CommandCatalog.bundledPages()).first { $0.id == id })
    }

    func testEveryAdvertisedLeafIsReachableExactlyOnce() throws {
        let pages = try CommandCatalog.bundledPages()
        let all = Dictionary(uniqueKeysWithValues: pages.map { ($0.path.joined(separator: " "), CommandDefinition.parse($0)) })
        var pending = [""]
        var visited = Set<String>()
        var leaves = Set<String>()
        while !pending.isEmpty {
            let id = pending.removeFirst()
            XCTAssertTrue(visited.insert(id).inserted, "Duplicate command: \(id)")
            let definition = try XCTUnwrap(all[id], "Missing help for \(id)")
            if definition.children.isEmpty { leaves.insert(id) }
            pending += definition.children.map { (definition.path + [$0]).joined(separator: " ") }
        }
        XCTAssertEqual(visited.count, 79)
        XCTAssertEqual(leaves.count, 67)
        XCTAssertEqual(leaves, Set(CommandCatalog.definitions(pages).map(\.id)))
        XCTAssertEqual(Set(CommandCatalog.definitions(pages).map(\.group)),
                       Set(["Container", "Image", "Registry", "Machine", "Volume", "Network", "System", "Build", "Builder", "Cluster"]))
    }

    func testEveryLeafBuildsArgumentsAndPreservesAllOptionValues() throws {
        for definition in try CommandCatalog.definitions(CommandCatalog.bundledPages()) {
            var draft = CommandDraft()
            draft.terminal = true
            for argument in definition.arguments { draft.positionals[argument.name] = "example" }
            for option in definition.options {
                draft.enabled.insert(option.flag)
                if option.takesValue { draft.values[option.flag] = ["value with spaces"] }
            }
            let arguments = try draft.arguments(for: definition)
            XCTAssertEqual(Array(arguments.prefix(definition.path.count)), definition.path)
            for option in definition.options {
                let index = try XCTUnwrap(arguments.firstIndex(of: option.flag), "\(definition.id): \(option.flag)")
                if option.takesValue { XCTAssertEqual(arguments[index + 1], "value with spaces") }
            }
            XCTAssertEqual(Set(definition.options.map(\.flag)).count, definition.options.count, definition.id)
        }
    }

    func testOptionParsingHandlesAliasesMultilineAndBooleanPairs() throws {
        let exec = try command("exec")
        XCTAssertEqual(exec.options.first { $0.flag == "--workdir" }?.valueName, "dir")
        XCTAssertTrue(exec.options.first { $0.flag == "--workdir" }?.description.contains("initial working directory") == true)
        XCTAssertEqual(exec.arguments.map(\.name), ["container-id", "arguments"])
        XCTAssertTrue(exec.arguments[1].repeated)
        XCTAssertFalse(exec.arguments[1].optional)
        let start = try command("system start")
        XCTAssertTrue(start.options.contains { $0.flag == "--enable-kernel-install" && !$0.takesValue })
        XCTAssertTrue(start.options.contains { $0.flag == "--disable-kernel-install" && !$0.takesValue })
        XCTAssertEqual(try command("logs").options.first { $0.flag == "-n" }?.valueName, "n")
        XCTAssertTrue(try command("build").arguments[0].optional)
        XCTAssertTrue(try command("run").arguments[1].optional)
    }

    func testAdvancedRunAndExecPreserveArgumentBoundaries() throws {
        var draft = CommandDraft()
        draft.enabled = ["--env", "--volume", "--network"]
        draft.values = ["--env": ["A=hello world", "B=$(touch /tmp/not-executed)"], "--volume": ["/tmp/my files:/data"], "--network": ["private"]]
        draft.positionals = ["image": "alpine", "arguments": #"sh -c 'echo "$A"'"#]
        let args = try draft.arguments(for: command("run"))
        XCTAssertTrue(args.contains("A=hello world"))
        XCTAssertTrue(args.contains("B=$(touch /tmp/not-executed)"))
        XCTAssertTrue(args.contains("/tmp/my files:/data"))
        XCTAssertEqual(Array(args.suffix(4)), ["alpine", "sh", "-c", "echo \"$A\""])
        XCTAssertEqual(args.filter { $0 == "--env" }.count, 2)
    }

    func testRequiredArgumentsArchivePathsAndRegistryCredentials() throws {
        XCTAssertThrowsError(try CommandDraft().arguments(for: command("exec")))
        var draft = CommandDraft()
        draft.positionals["id"] = "web"
        XCTAssertThrowsError(try draft.arguments(for: command("export")))
        draft.enabled = ["--output"]; draft.values["--output"] = ["/tmp/archive.tar"]
        XCTAssertEqual(try draft.arguments(for: command("export")), ["export", "--output", "/tmp/archive.tar", "web"])
        draft = CommandDraft()
        draft.positionals["server"] = "registry.example.com"
        XCTAssertThrowsError(try draft.arguments(for: command("registry login")))
        draft.password = "secret-token"
        draft.enabled = ["--username"]; draft.values["--username"] = ["alice"]
        let login = try draft.arguments(for: command("registry login"))
        XCTAssertTrue(login.contains("--password-stdin"))
        XCTAssertFalse(login.contains("secret-token"))
        XCTAssertThrowsError(try CommandDraft().arguments(for: command("image load")))
        draft = CommandDraft()
        draft.positionals = ["container-id": "web", "arguments": "   "]
        XCTAssertThrowsError(try draft.arguments(for: command("exec")))
    }

    func testTerminalAndDestructiveRouting() throws {
        XCTAssertTrue(try command("system dns create").administrator)
        XCTAssertFalse(try command("system dns list").administrator)
        for id in ["delete", "prune", "image delete", "volume prune", "network delete", "cluster delete", "system stop"] {
            XCTAssertTrue(try command(id).destructive, id)
        }
        for id in ["list", "inspect", "stats", "build", "image pull"] { XCTAssertFalse(try command(id).destructive, id) }
        var draft = CommandDraft()
        draft.enabled.insert("--tty")
        XCTAssertTrue(try draft.requiresTerminal(for: command("exec")))
        XCTAssertTrue(try CommandDraft().requiresTerminal(for: command("machine run")))
        draft = CommandDraft()
        draft.additional = "-it"
        XCTAssertTrue(try draft.requiresTerminal(for: command("exec")))
        XCTAssertEqual(try CommandDraft().arguments(for: command("system start")), ["system", "start", "--enable-kernel-install"])
    }

    func testTokenizerDoesNotExpandShellSyntax() throws {
        XCTAssertEqual(try ArgumentWords.parse(#"one 'two three' "four five" six\ seven '' '$HOME' '$(id)' ';'"#),
                       ["one", "two three", "four five", "six seven", "", "$HOME", "$(id)", ";"])
        XCTAssertThrowsError(try ArgumentWords.parse("'unclosed"))
        XCTAssertThrowsError(try ArgumentWords.parse("unfinished\\"))
        XCTAssertEqual(ArgumentWords.quote("it's $HOME"), "'it'\\''s $HOME'")
    }
}
