import SwiftUI

struct ResourceView: View {
    @Bindable var store: Store
    let kind: ResourceKind
    @State private var search = ""
    @State private var selection: ResourceItem.ID?
    @State private var showInspector = false

    var items: [ResourceItem] { store.inventories[kind] ?? [] }
    var filtered: [ResourceItem] {
        guard !search.isEmpty else { return items }
        return items.filter { item in
            ([item.id, item.state, kind.subtitle.flatMap(item.value)] + kind.fields.map(item.value))
                .compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }
    var selected: ResourceItem? { items.first { $0.id == selection } }
    var hasDetails: Bool { kind.inspectCommand != nil || kind.logsCommand != nil || !kind.fields.isEmpty }

    var body: some View {
        Group {
            if items.isEmpty, let failure = store.inventoryErrors[kind] {
                ContentUnavailableView {
                    Label("Couldn’t Load \(kind.title)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure).textSelection(.enabled).frame(maxWidth: 520)
                } actions: {
                    Button("Try Again") { Task { await store.refresh() } }.disabled(store.refreshing)
                }
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label(kind.empty.title, systemImage: kind.symbol)
                } description: {
                    Text(kind.empty.message)
                } actions: {
                    if let primary = kind.collectionActions.first {
                        Button(primary.title) { store.invoke(primary) }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.busy)
                    }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                list
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search \(kind.title.lowercased())")
        .inspector(isPresented: $showInspector) {
            Group {
                if let selected {
                    ResourceInspector(store: store, kind: kind, item: selected)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "sidebar.trailing",
                                           description: Text("Select a \(kind.singular) to see its details."))
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 380, max: 620)
        }
        .toolbar { toolbar }
        .onChange(of: selection) { _, id in if id != nil { showInspector = true } }
    }

    var list: some View {
        List(filtered, selection: $selection) { item in
            ResourceRow(kind: kind, item: item).tag(item.id).listRowSeparator(.hidden)
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: ResourceItem.ID.self) { ids in
            if let item = items.first(where: { ids.first == $0.id }) {
                ActionMenuItems(store: store, kind: kind, item: item)
            }
        } primaryAction: { ids in
            selection = ids.first
            showInspector = true
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let actions = kind.collectionActions
            if let primary = actions.first {
                Button { store.invoke(primary) } label: { Label(primary.title, systemImage: primary.symbol) }
                    .help(primary.title.replacingOccurrences(of: "…", with: ""))
                    .disabled(store.busy)
            }
            if actions.count > 1 {
                Menu {
                    ForEach(actions.dropFirst()) { action in
                        Button(action.title, systemImage: action.symbol) { store.invoke(action) }
                    }
                } label: { Label("More \(kind.title) Actions", systemImage: "ellipsis.circle") }
                    .help("More \(kind.singular) actions")
                    .disabled(store.busy)
            }
            if hasDetails || !kind.itemActions.isEmpty {
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help(showInspector ? "Hide inspector" : "Show inspector")
            }
        }
    }
}

struct ResourceRow: View {
    let kind: ResourceKind
    let item: ResourceItem

    var title: String {
        kind == .images ? ImageReference(reference: item.id).displayName : item.id
    }

    var body: some View {
        // Fields drop from the end when space is tight, so the name always stays readable.
        ViewThatFits(in: .horizontal) {
            row(fields: kind.fields)
            row(fields: Array(kind.fields.dropLast()))
            row(fields: Array(kind.fields.dropLast(2)))
            row(fields: [])
        }
        .padding(.vertical, 5)
    }

    func row(fields: [ResourceField]) -> some View {
        HStack(spacing: 12) {
            if item.state != nil {
                StatusDot(active: item.running)
            } else {
                Image(systemName: kind.symbol).foregroundStyle(.tint).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                if let subtitle = kind.subtitle, let value = item.value(subtitle) {
                    Text(kind == .images ? String(value.replacingOccurrences(of: "sha256:", with: "").prefix(12)) : value)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .help(item.id)
            Spacer(minLength: 16)
            ForEach(fields) { field in
                Group {
                    if let value = item.value(field) {
                        Label(value, systemImage: field.symbol).help(field.label)
                    } else {
                        Color.clear
                    }
                }
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: field.width, alignment: .leading)
            }
            if let state = item.state {
                StatePill(state: state, active: item.running).frame(width: 76, alignment: .trailing)
            }
        }
    }
}

/// The verbs for one resource, shared by context menus and the inspector.
struct ActionMenuItems: View {
    @Bindable var store: Store
    let kind: ResourceKind
    let item: ResourceItem

    var body: some View {
        let actions = kind.itemActions.filter { $0.available(for: item) }
        let destructive = actions.filter { store.catalog.command($0.path)?.destructive ?? false }
        ForEach(actions.filter { action in !destructive.contains { $0.id == action.id } }) { action in
            Button(action.title, systemImage: action.symbol) { store.invoke(action, on: item) }.disabled(store.busy)
        }
        Divider()
        Button("Copy Name", systemImage: "doc.on.doc") { copyToPasteboard(item.id) }
        if !destructive.isEmpty {
            Divider()
            ForEach(destructive) { action in
                Button(action.title + "…", systemImage: action.symbol, role: .destructive) { store.invoke(action, on: item) }
                    .disabled(store.busy)
            }
        }
    }
}

struct ResourceInspector: View {
    enum Tab: String, CaseIterable { case overview = "Overview", logs = "Logs", json = "JSON" }

    @Bindable var store: Store
    let kind: ResourceKind
    let item: ResourceItem
    @State private var tab = Tab.overview
    @State private var detail = ""
    @State private var loading = false

    var tabs: [Tab] {
        [.overview] + (kind.logsCommand == nil ? [] : [.logs]) + (kind.inspectCommand == nil ? [] : [.json])
    }
    var actions: [ResourceAction] { kind.itemActions.filter { $0.available(for: item) } }
    var primary: ResourceAction? {
        actions.first { $0.behavior != .form && !(store.catalog.command($0.path)?.destructive ?? false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SymbolTile(symbol: kind.symbol,
                           tint: item.state == nil ? .accentColor : item.running ? .green : .secondary, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ResourceRow(kind: kind, item: item).title)
                        .font(.headline).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let state = item.state {
                        StatePill(state: state, active: item.running)
                    } else {
                        Text(kind.singular.capitalized).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if !actions.isEmpty {
                HStack(spacing: 8) {
                    if let primary {
                        Button { store.invoke(primary, on: item) } label: {
                            Label(primary.title, systemImage: primary.symbol).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Menu {
                        ActionMenuItems(store: store, kind: kind, item: item)
                    } label: {
                        Label(primary == nil ? "Actions" : "More", systemImage: "ellipsis.circle")
                            .frame(maxWidth: primary == nil ? .infinity : nil)
                    }
                    .fixedSize(horizontal: primary != nil, vertical: false)
                }
                .controlSize(.large)
                .disabled(store.busy)
            }
            if tabs.count > 1 {
                Picker("View", selection: $tab) {
                    ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            switch tab {
            case .overview: RecordOverview(item: item)
            case .logs, .json: detailView
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: "\(item.id)-\(tab)") { await load() }
    }

    var detailView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tab == .logs ? "Last 200 lines" : "container \((kind.inspectCommand ?? []).joined(separator: " "))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(detail) }.disabled(detail.isEmpty)
                Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            ConsoleView(text: loading && detail.isEmpty ? "" : detail,
                        placeholder: loading ? "Loading…" : "No output.", wraps: true, follows: tab == .logs)
        }
    }

    func load() async {
        let command: [String]? = switch tab {
        case .overview: nil
        case .logs: kind.logsCommand
        case .json: kind.inspectCommand
        }
        guard let command else { return }
        let id = item.id
        detail = ""
        loading = true
        defer { loading = false }
        do {
            let output = try await store.cli.run(command + [id])
            if item.id == id { detail = output }
        } catch is CancellationError {
        } catch { if item.id == id { detail = error.localizedDescription } }
    }
}

/// Every reported value of a record, grouped by its top-level key.
struct RecordOverview: View {
    let item: ResourceItem
    var scrolls = true

    var sections: [(title: String, rows: [(label: String, value: String)])] {
        guard case .object(let object) = item.record else { return [] }
        var general: [(String, String)] = []
        var nested: [(String, [(String, String)])] = []
        for key in object.keys.sorted() {
            let value = object[key, default: .null]
            if !value.isGroup {
                if let text = Self.format(value, key: key), text != item.id { general.append((Self.humanize(key), text)) }
            } else {
                let rows = value.leaves().compactMap { leaf -> (String, String)? in
                    guard let text = Self.format(leaf.value, key: leaf.path.last ?? key), text != item.id else { return nil }
                    return (leaf.path.map(Self.humanize).joined(separator: " › "), text)
                }
                if !rows.isEmpty { nested.append((Self.humanize(key), rows)) }
            }
        }
        return (general.isEmpty ? [] : [("General", general)]) + nested
    }

    var body: some View {
        if sections.isEmpty {
            DetailRow(label: "Name") { Text(item.id).textSelection(.enabled) }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Spacer()
        } else if scrolls {
            ScrollView { groups }
        } else {
            groups
        }
    }

    var groups: some View {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                                    if index > 0 { Divider() }
                                    DetailRow(label: row.label) { Text(row.value).textSelection(.enabled) }
                                }
                            }
                            .padding(.horizontal, 12)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
    }

    static func format(_ value: JSONValue, key: String) -> String? {
        let format = FieldFormat.guess(forKey: key)
        guard format == .date, let text = value.text, let date = FieldFormat.parseDate(text) else {
            return format.display(value)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func humanize(_ key: String) -> String {
        // Label keys such as com.apple.container.resource.role are identifiers, not words.
        guard key.allSatisfy({ $0.isLetter || $0.isNumber }) else { return key }
        // Byte values are already formatted with units.
        let key = key.hasSuffix("InBytes") && key.count > 7 ? String(key.dropLast(7)) : key
        let acronyms = ["id": "ID", "ipv4": "IPv4", "ipv6": "IPv6", "cpus": "CPUs", "dns": "DNS", "uid": "UID", "gid": "GID",
                        "mtu": "MTU", "url": "URL", "os": "OS", "ssh": "SSH", "mac": "MAC", "ip": "IP"]
        var words: [String] = []
        var current = ""
        for character in key {
            if character.isUppercase, let last = current.last, last.isLowercase || last.isNumber {
                words.append(current); current = ""
            }
            current.append(character)
        }
        words.append(current)
        return words.enumerated().map { index, word in
            if let acronym = acronyms[word.lowercased()] { return acronym }
            return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word.lowercased()
        }.joined(separator: " ")
    }
}

struct DetailRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 140, alignment: .leading).lineLimit(2)
            content.frame(maxWidth: .infinity, alignment: .leading).lineLimit(3).truncationMode(.middle)
        }
        .font(.callout)
        .padding(.vertical, 8)
    }
}
