import SwiftUI
import AppKit

@main
struct ContainerDeskApp: App {
    @State private var store = Store()
    init() {
        if ProcessInfo.processInfo.arguments.contains("--check-catalog") {
            do {
                let commands = CommandCatalog.definitions(try CommandCatalog.bundledPages())
                print("Catalog verified: \(commands.count) operations")
                exit(commands.isEmpty ? 1 : 0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .task { await store.refresh(); await store.catalog.reload() }
        }
        .defaultSize(width: 1200, height: 780)
        .commands { CommandGroup(after: .newItem) {
            Button("Refresh") { Task { await store.refresh() } }.keyboardShortcut("r")
        } }
    }
}

struct ContentView: View {
    @Bindable var store: Store
    @Environment(\.scenePhase) private var scenePhase
    @State private var kind = ResourceKind.containers

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store, selection: $kind)
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            detail
                .id(kind)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(kind.title)
                .navigationSubtitle(subtitle)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .help("Refresh (⌘R)")
                            .disabled(store.refreshing || store.busy)
                    }
                }
        }
        .sheet(item: $store.sheet) { sheet in
            switch sheet {
            case .newContainer(let image): RunSheet(store: store, initialImage: image)
            case .command(let request): CommandSheet(store: store, request: request)
            }
        }
        .confirmationDialog("\(store.pendingConfirmation?.label ?? "Continue")?",
                            isPresented: Binding(get: { store.pendingConfirmation != nil },
                                                 set: { if !$0 { store.pendingConfirmation = nil } })) {
            if let request = store.pendingConfirmation {
                Button(request.title.replacingOccurrences(of: "…", with: ""), role: .destructive) {
                    Task { await store.run(request) }
                    store.pendingConfirmation = nil
                }
            }
        } message: { Text("This can remove data or stop running workloads, and can’t be undone.") }
        // Sheets show failures inline; presenting this alert over them would duplicate the message.
        .alert("Command failed", isPresented: Binding(
            get: { store.error != nil && store.sheet == nil },
            set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
    }

    @ViewBuilder var detail: some View {
        if kind == .system {
            SystemView(store: store)
        } else if store.connected {
            ResourceView(store: store, kind: kind)
        } else {
            SystemUnavailableView(store: store)
        }
    }

    var subtitle: String {
        guard store.connected, kind != .system else { return "" }
        let items = store.inventories[kind] ?? []
        if kind == .builder { return items.isEmpty ? "Not running" : "Running" }
        if kind == .containers {
            return "\(items.filter(\.running).count) running · \(items.count) total"
        }
        return items.count == 1 ? "1 \(kind.singular)" : "\(items.count) \(kind.title.lowercased())"
    }
}

struct Sidebar: View {
    @Bindable var store: Store
    @Binding var selection: ResourceKind

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.kinds) { kind in
                        Label(kind.title, systemImage: kind.symbol)
                            .badge(store.connected ? store.inventories[kind]?.count ?? 0 : 0)
                            .tag(kind)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SystemStatusCard(store: store).padding(10) }
    }
}

struct SystemStatusCard: View {
    @Bindable var store: Store

    var title: String {
        if store.connected { return "System running" }
        return ContainerCLI.executable == nil ? "CLI not installed" : "System stopped"
    }

    var detail: String {
        if store.operation.running { return "Operation in progress…" }
        if store.busy { return "\(store.activity)…" }
        if store.refreshing { return "Refreshing…" }
        return store.activity == "Ready" ? "Apple container · Local" : store.activity
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(active: store.connected)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if store.busy || store.refreshing { ProgressView().controlSize(.small) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(detail)
        .accessibilityElement(children: .combine)
    }
}

struct SystemUnavailableView: View {
    @Bindable var store: Store

    var body: some View {
        ContentUnavailableView {
            Label(ContainerCLI.executable == nil ? "Apple container isn’t installed" : "The container system is stopped",
                  systemImage: "shippingbox")
        } description: {
            Text(store.connectionError ?? "Connecting to Apple container…")
                .textSelection(.enabled)
                .frame(maxWidth: 520)
        } actions: {
            if ContainerCLI.executable == nil {
                Link("Download Apple container", destination: URL(string: "https://github.com/apple/container/releases")!)
                    .buttonStyle(.borderedProminent)
            } else {
                VStack(spacing: 8) {
                    Button {
                        Task { await store.perform(["system", "start", "--enable-kernel-install"], label: "Start system") }
                    } label: {
                        Label(store.busy ? "Starting…" : "Start Container System", systemImage: "power")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.busy || store.refreshing)
                    Text("Downloads the recommended Linux kernel if needed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
