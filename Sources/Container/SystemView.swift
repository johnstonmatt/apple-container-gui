import SwiftUI
import AppKit

struct SystemView: View {
    @Bindable var store: Store
    @State private var status: JSONValue?
    @State private var versions: JSONValue?
    @State private var usage: JSONValue?
    @State private var properties: JSONValue?
    @State private var cli = ContainerCLI.resolution
    @State private var cliError: String?

    var running: Bool { status?["status"]?.text.map { $0 == "running" } ?? store.connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                overview
                cliSection
                if store.dependencies != .ready {
                    section("Dependencies", footer: "No installation happens until you choose a setup action.") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(store.dependencies.title).font(.headline)
                            Text(store.dependencies.message).foregroundStyle(.secondary).textSelection(.enabled)
                            DependencyActions(store: store)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                if store.connected, let usage { diskUsage(usage) }
                if store.connected, let properties {
                    section("Properties", footer: "Defaults the CLI uses for new containers, builds, and machines.") {
                        RecordOverview(item: ResourceItem(id: "properties", record: properties), scrolls: false)
                    }
                }
                otherCommands
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(ResourceKind.system.collectionActions.filter { $0.behavior == .form }) { action in
                        Button(action.title, systemImage: action.symbol) { store.invoke(action) }
                    }
                } label: { Label("More System Actions", systemImage: "ellipsis.circle") }
                    .disabled(store.busy)
            }
        }
        .task { await load() }
        .onChange(of: store.refreshing) { _, refreshing in if !refreshing { Task { await load() } } }
    }

    var overview: some View {
        HStack(alignment: .center, spacing: 16) {
            SymbolTile(symbol: "cpu", tint: store.connected ? .green : .secondary, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Container System").font(.title2.weight(.semibold))
                    StatePill(state: store.dependencies.shortTitle, active: store.connected)
                }
                Text(versionLine).foregroundStyle(.secondary)
                if let host = hostLine { Text(host).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            if let action = ResourceKind.system.collectionActions.first(where: { $0.path == (running ? ["system", "stop"] : ["system", "start"]) }) {
                Button { store.invoke(action) } label: { Label(action.title, systemImage: action.symbol) }
                    .buttonStyle(.borderedProminent)
                    .tint(running ? .secondary : .accentColor)
                    .controlSize(.large)
                    .disabled(store.busy || ContainerCLI.executable == nil)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var cliSection: some View {
        section("Container CLI", footer: "Container starts, stops, and runs everything with this CLI, so choose the install whose services you want to use.") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cli.path ?? cli.requested ?? "No container CLI found")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(cli.path == nil ? .red : .primary)
                            .textSelection(.enabled)
                        Text(cliSourceLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if cli.source == .chosen {
                        Button("Find Automatically") { useCLI(nil) }.disabled(store.busy)
                    }
                    Button("Choose…") { chooseCLI() }
                        .disabled(store.busy || cli.source == .environment)
                        .help(cli.source == .environment ? "\(ContainerCLI.environmentKey) is set, so it decides the CLI." : "Choose a container executable")
                }
                if let cliError { Text(cliError).font(.caption).foregroundStyle(.red) }
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    var cliSourceLine: String {
        switch cli.source {
        case .environment: "Set by \(ContainerCLI.environmentKey)"
        case .chosen: "Chosen in Container"
        case .automatic: "Found automatically in /usr/local/bin, /opt/homebrew/bin, or PATH"
        }
    }

    func chooseCLI() {
        let panel = NSOpenPanel()
        panel.message = "Choose a container executable"
        panel.prompt = "Use"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Builds installed outside /usr/local, eg. under ~/.local, live in hidden folders.
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: cli.path ?? "/usr/local/bin/container").deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            cliError = "\(url.path) isn’t an executable file."
            return
        }
        useCLI(url.path)
    }

    func useCLI(_ path: String?) {
        ContainerCLI.choose(path)
        cli = ContainerCLI.resolution
        cliError = nil
        // A different CLI can mean different services and commands, so check both again.
        Task {
            await store.refresh()
            await store.catalog.reload()
        }
    }

    var versionLine: String {
        guard case .array(let components)? = versions, !components.isEmpty else {
            return ContainerCLI.executable == nil ? "Apple container isn’t installed" : "Apple container"
        }
        return components.compactMap { component in
            guard let version = component["version"]?.text else { return nil }
            let name = component["appName"]?.text == "container-apiserver" ? "API server" : "CLI"
            return "\(name) \(version)"
        }.joined(separator: " · ")
    }

    var hostLine: String? {
        guard let host = status?["host"] else { return nil }
        let parts = [host["architecture"]?.text, host["cpus"]?.text.map { "\($0) CPUs" }, host["operatingSystem"]?.text.map { "macOS " + $0.replacingOccurrences(of: "Version ", with: "") }]
        let line = parts.compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    func diskUsage(_ usage: JSONValue) -> some View {
        let rows: [(title: String, key: String, kind: ResourceKind, cleanup: [String])] = [
            ("Containers", "containers", .containers, ["prune"]),
            ("Images", "images", .images, ["image", "prune"]),
            ("Volumes", "volumes", .volumes, ["volume", "prune"])
        ]
        return section("Disk Usage", footer: "Reclaimable space belongs to stopped containers and resources nothing uses.") {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    usageRow(title: row.title, value: usage[row.key], kind: row.kind,
                             cleanup: row.kind.collectionActions.first { $0.path == row.cleanup })
                }
            }
            .padding(.horizontal, 14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    func usageRow(title: String, value: JSONValue?, kind: ResourceKind, cleanup: ResourceAction?) -> some View {
        let size = value?["sizeInBytes"].flatMap { FieldFormat.bytes.display($0) } ?? "—"
        let reclaimable: Double = if case .number(let bytes)? = value?["reclaimable"] { bytes } else { 0 }
        let total: Double = if case .number(let bytes)? = value?["sizeInBytes"] { bytes } else { 0 }
        let count = value?["total"]?.text ?? "0"
        let active = value?["active"]?.text ?? "0"
        return HStack(spacing: 14) {
            Image(systemName: kind.symbol).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Text("\(count) total · \(active) in use").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(size).monospacedDigit()
                }
                ProgressView(value: total > 0 ? reclaimable / total : 0)
                    .tint(.orange)
                    .help("\(ByteCountFormatter.string(fromByteCount: Int64(reclaimable), countStyle: .file)) reclaimable")
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(reclaimable), countStyle: .file)) reclaimable")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let cleanup {
                Button(cleanup.title) { store.invoke(cleanup) }
                    .disabled(store.busy || reclaimable == 0)
            }
        }
        .padding(.vertical, 12)
    }

    var otherCommands: some View {
        section("Command Catalog", footer: store.catalog.unmapped.isEmpty
                ? "Every command the installed CLI offers is available from its resource."
                : "These commands aren’t tied to a resource view, usually because a plugin added them.") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(store.catalog.source, systemImage: "book.closed").foregroundStyle(.secondary)
                    Spacer()
                    if store.catalog.loading { ProgressView().controlSize(.small) }
                    Button("Reload from Installed CLI") { Task { await store.catalog.reload() } }
                        .disabled(store.catalog.loading || store.busy)
                }
                .padding(.vertical, 10)
                ForEach(store.catalog.unmapped) { command in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.id).font(.system(.callout, design: .monospaced).weight(.medium))
                            Text(command.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Run…") {
                            store.sheet = .command(CommandRequest(command: command, draft: CommandDraft(),
                                                                  title: command.id, symbol: "terminal"))
                        }
                        .disabled(store.busy)
                    }
                    .padding(.vertical, 8)
                }
                if let error = store.catalog.error {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.bottom, 8)
                }
            }
            .padding(.horizontal, 14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    func section(_ title: String, footer: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
            Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func load() async {
        cli = ContainerCLI.resolution
        guard ContainerCLI.executable != nil else {
            status = nil; versions = nil; usage = nil; properties = nil
            return
        }
        func json(_ arguments: [String]) async -> JSONValue? {
            guard let output = try? await store.cli.run(arguments) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        }
        status = await json(["system", "status", "--format", "json"])
        versions = await json(["system", "version", "--format", "json"])
        guard store.connected else { usage = nil; properties = nil; return }
        usage = await json(["system", "df", "--format", "json"])
        properties = await json(["system", "property", "list", "--format", "json"])
    }
}
