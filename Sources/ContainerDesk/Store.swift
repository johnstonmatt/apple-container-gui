import SwiftUI

struct CommandRequest: Identifiable {
    let id = UUID()
    let command: CommandDefinition
    var draft: CommandDraft
    let title: String
    let symbol: String
    var subject: String?
    var confirms = false

    var label: String { [title.replacingOccurrences(of: "…", with: ""), subject].compactMap { $0 }.joined(separator: " ") }
}

enum ActiveSheet: Identifiable {
    case newContainer(image: String)
    case command(CommandRequest)

    var id: String {
        switch self {
        case .newContainer(let image): "new-container-\(image)"
        case .command(let request): request.id.uuidString
        }
    }
}

@MainActor @Observable
final class CatalogModel {
    var commands: [CommandDefinition] = []
    var loading = false
    var error: String?
    var source = "Bundled CLI 1.7.1 catalog"

    init() {
        do { commands = CommandCatalog.definitions(try CommandCatalog.bundledPages()) }
        catch { self.error = error.localizedDescription }
    }

    func command(_ path: [String]) -> CommandDefinition? { commands.first { $0.path == path } }

    /// Commands the installed CLI offers that no resource view maps, such as newly installed plugins.
    var unmapped: [CommandDefinition] {
        let covered = ResourceKind.coveredCommandIDs
        return commands.filter { !covered.contains($0.id) }
    }

    func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let pages = try await CommandCatalog.discover(using: ContainerCLI())
            commands = CommandCatalog.definitions(pages)
            source = "Installed CLI · \(commands.count) commands"
            error = nil
        } catch { self.error = "Catalog refresh failed; keeping the previous catalog. \(error.localizedDescription)" }
    }
}

@MainActor @Observable
final class Store {
    var containers: [ContainerRecord] = []
    var inventories: [ResourceKind: [ResourceItem]] = [:]
    var inventoryErrors: [ResourceKind: String] = [:]
    var connected = false
    var refreshing = false
    private var actionRunning = false
    var busy: Bool { actionRunning || operation.running }
    let operation = OperationSession()
    let catalog = CatalogModel()
    var error: String?
    var connectionError: String?
    var activity = "Ready"
    var sheet: ActiveSheet?
    var pendingConfirmation: CommandRequest?
    let cli = ContainerCLI()

    var images: [String] { (inventories[.images] ?? []).map(\.id) }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let output = try await cli.run(ResourceKind.containers.jsonListArguments ?? [])
            containers = try JSONDecoder().decode([ContainerRecord].self, from: Data(output.utf8))
            inventories[.containers] = try ResourceKind.containers.items(fromJSON: output) ?? []
            connected = true
            connectionError = nil
        } catch {
            connected = false
            connectionError = error.localizedDescription
            return
        }
        let kinds = ResourceKind.allCases.filter { $0 != .containers && $0.listCommand != nil }
        let loads = kinds.map { kind in Task { await loadInventory(kind) } }
        for load in loads {
            let loaded = await load.value
            if let items = loaded.items { inventories[loaded.kind] = items }
            inventoryErrors[loaded.kind] = loaded.error
        }
    }

    private struct InventoryLoad: Sendable {
        let kind: ResourceKind
        var items: [ResourceItem]?
        var error: String?
    }

    private func loadInventory(_ kind: ResourceKind) async -> InventoryLoad {
        do {
            if let json = kind.jsonListArguments, let items = try kind.items(fromJSON: try await cli.run(json)) {
                return InventoryLoad(kind: kind, items: items)
            }
            let quiet = try await cli.run(kind.quietListArguments ?? [])
            return InventoryLoad(kind: kind, items: ResourceKind.items(fromQuiet: quiet))
        } catch { return InventoryLoad(kind: kind, error: error.localizedDescription) }
    }

    @discardableResult
    func perform(_ arguments: [String], label: String) async -> Bool {
        guard !busy else { return false }
        actionRunning = true
        activity = label
        defer { actionRunning = false }
        do {
            _ = try await cli.run(arguments, timeout: 600)
            activity = "\(label) completed"
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            activity = "\(label) failed"
            return false
        }
    }

    func request(_ action: ResourceAction, on item: ResourceItem?) -> CommandRequest? {
        guard let command = catalog.command(action.path) else {
            error = "The installed container CLI doesn’t provide “\(action.path.joined(separator: " "))”."
            return nil
        }
        return CommandRequest(command: command, draft: action.draft(for: command, subject: item?.id),
                              title: action.title, symbol: action.symbol, subject: item?.id, confirms: action.confirms)
    }

    func invoke(_ action: ResourceAction, on item: ResourceItem? = nil) {
        if action.behavior == .quickRun {
            sheet = .newContainer(image: item?.id ?? "")
            return
        }
        guard let request = request(action, on: item) else { return }
        switch action.behavior {
        case .form, .quickRun:
            sheet = .command(request)
        case .immediate:
            if request.command.destructive || request.confirms { pendingConfirmation = request } else { Task { await run(request) } }
        }
    }

    func run(_ request: CommandRequest) async {
        var draft = request.draft
        draft.terminal = draft.requiresTerminal(for: request.command)
        do {
            let arguments = try draft.arguments(for: request.command)
            if draft.terminal {
                guard let executable = ContainerCLI.executable else { throw CLIError(message: "Install Apple container to get started.") }
                try await TerminalScript.open(executable: executable, arguments: arguments,
                                              directory: draft.directory, administrator: request.command.administrator)
                activity = "\(request.label) opened in Terminal"
            } else {
                await perform(arguments, label: request.label)
            }
        } catch { self.error = error.localizedDescription }
    }
}
