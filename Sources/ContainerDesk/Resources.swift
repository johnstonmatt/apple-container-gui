import Foundation
import CoreGraphics

struct ResourceItem: Identifiable, Hashable, Sendable {
    let id: String
    /// The CLI's JSON record, or `.null` when only identifiers were available.
    let record: JSONValue

    var state: String? {
        ["status.state", "status", "state"].lazy.compactMap { self.record[$0]?.text }.first
    }
    var running: Bool { state?.lowercased() == "running" }

    func value(_ field: ResourceField) -> String? {
        guard let value = record[field.path] else { return nil }
        return field.format.display(value)
    }
}

enum FieldFormat: Sendable {
    case text, bytes, date, image

    func display(_ value: JSONValue) -> String? {
        switch self {
        case .text: return value.text
        case .bytes:
            guard case .number(let bytes) = value else { return value.text }
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        case .date:
            guard let text = value.text, let date = Self.parseDate(text) else { return value.text }
            return date.formatted(.relative(presentation: .named))
        case .image:
            return value.text.map { ImageReference(reference: $0).displayName }
        }
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// Picks a format for an arbitrary key from naming conventions in the CLI's JSON.
    static func guess(forKey key: String) -> Self {
        if key.hasSuffix("InBytes") || key == "size" { return .bytes }
        if key.hasSuffix("Date") || key == "created" { return .date }
        return .text
    }
}

struct ResourceField: Identifiable, Sendable {
    let label: String
    let symbol: String
    let path: String
    var format = FieldFormat.text
    /// Fixed so values line up across rows even when some are missing.
    var width: CGFloat = 120
    var id: String { path }
}

struct ResourceAction: Identifiable, Sendable {
    enum Subject: Sendable {
        case none
        case argument(String)
        case option(String)
        /// Prefills `<resource>:` so the person only completes the path inside it.
        case argumentPrefix(String)
    }
    enum Behavior: Sendable { case immediate, form, quickRun }
    enum Availability: Sendable { case always, running, stopped }

    let title: String
    let symbol: String
    let path: [String]
    var subject = Subject.none
    var behavior = Behavior.form
    var availability = Availability.always
    var options: [String: [String]] = [:]
    var arguments: [String: String] = [:]
    /// Asks first even when the CLI command itself is not destructive.
    var confirms = false
    var id: String { "\(path.joined(separator: " ")) \(title)" }

    func available(for item: ResourceItem?) -> Bool {
        switch availability {
        case .always: true
        case .running: item?.running ?? true
        case .stopped: !(item?.running ?? false)
        }
    }

    func draft(for command: CommandDefinition, subject value: String?) -> CommandDraft {
        var draft = CommandDraft()
        for (flag, values) in options {
            draft.enabled.insert(flag)
            if !values.isEmpty { draft.values[flag] = values }
        }
        draft.positionals.merge(arguments) { _, new in new }
        guard let value else { return draft }
        switch subject {
        case .none: break
        case .argument(let name):
            let repeated = command.arguments.first { $0.name == name }?.repeated ?? false
            draft.positionals[name] = repeated ? ArgumentWords.display(value) : value
        case .option(let flag):
            draft.enabled.insert(flag)
            draft.values[flag] = [value]
        case .argumentPrefix(let name):
            draft.positionals[name] = value + ":"
        }
        return draft
    }
}

enum SidebarGroup: String, CaseIterable, Identifiable {
    case workloads = "Workloads", resources = "Resources", environment = "Environment"
    var id: Self { self }
    var kinds: [ResourceKind] { ResourceKind.allCases.filter { $0.group == self } }
}

enum ResourceKind: String, CaseIterable, Identifiable, Sendable {
    case containers, machines, clusters, images, volumes, networks, builder, registries, dnsDomains, system

    var id: Self { self }

    var group: SidebarGroup {
        switch self {
        case .containers, .machines, .clusters: .workloads
        case .images, .volumes, .networks: .resources
        case .builder, .registries, .dnsDomains, .system: .environment
        }
    }

    var title: String {
        switch self {
        case .containers: "Containers"
        case .machines: "Machines"
        case .clusters: "Clusters"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .builder: "Builder"
        case .registries: "Registries"
        case .dnsDomains: "DNS Domains"
        case .system: "System"
        }
    }

    var singular: String {
        switch self {
        case .containers: "container"
        case .machines: "machine"
        case .clusters: "cluster"
        case .images: "image"
        case .volumes: "volume"
        case .networks: "network"
        case .builder: "builder"
        case .registries: "registry"
        case .dnsDomains: "domain"
        case .system: "system"
        }
    }

    var symbol: String {
        switch self {
        case .containers: "shippingbox"
        case .machines: "desktopcomputer"
        case .clusters: "circle.hexagongrid"
        case .images: "square.3.layers.3d"
        case .volumes: "externaldrive"
        case .networks: "network"
        case .builder: "hammer"
        case .registries: "server.rack"
        case .dnsDomains: "globe"
        case .system: "cpu"
        }
    }

    var empty: (title: String, message: String) {
        switch self {
        case .containers: ("No Containers Yet", "Each container runs in its own lightweight Linux virtual machine. Start one from any OCI image.")
        case .machines: ("No Machines", "Machines are long-lived Linux environments with your home folder mounted. Create one from an image.")
        case .clusters: ("No Clusters", "Create a local Kubernetes cluster whose nodes run as containers. This feature is experimental.")
        case .images: ("No Local Images", "Pull an image from a registry, or build one from a Dockerfile.")
        case .volumes: ("No Volumes", "Volumes keep data beyond a container’s lifetime. Create one, then mount it when you run a container.")
        case .networks: ("No Networks", "Create a network to isolate a group of containers or give them their own subnet.")
        case .builder: ("Builder Not Running", "The builder runs image builds in a dedicated container. Start it to choose its CPU and memory.")
        case .registries: ("No Registry Logins", "Log in to a registry to push images or pull private ones.")
        case .dnsDomains: ("No Local DNS Domains", "Create a local domain, such as test, so containers are reachable by name. Requires administrator approval.")
        case .system: ("", "")
        }
    }

    /// The command that lists this resource; nil for the system singleton.
    var listCommand: (path: [String], flags: [String])? {
        switch self {
        case .containers: (["list"], ["--all"])
        case .machines: (["machine", "list"], [])
        case .clusters: (["cluster", "list"], [])
        case .images: (["image", "list"], [])
        case .volumes: (["volume", "list"], [])
        case .networks: (["network", "list"], [])
        case .builder: (["builder", "status"], [])
        case .registries: (["registry", "list"], [])
        case .dnsDomains: (["system", "dns", "list"], [])
        case .system: nil
        }
    }

    var jsonListArguments: [String]? { listCommand.map { $0.path + $0.flags + ["--format", "json"] } }
    var quietListArguments: [String]? { listCommand.map { $0.path + $0.flags + ["--quiet"] } }

    var inspectCommand: [String]? {
        switch self {
        case .containers: ["inspect"]
        case .machines: ["machine", "inspect"]
        case .images: ["image", "inspect"]
        case .volumes: ["volume", "inspect"]
        case .networks: ["network", "inspect"]
        case .clusters, .builder, .registries, .dnsDomains, .system: nil
        }
    }

    var logsCommand: [String]? {
        switch self {
        case .containers: ["logs", "-n", "200"]
        case .machines: ["machine", "logs", "-n", "200"]
        default: nil
        }
    }

    /// Commands whose output the System view shows directly.
    var readCommands: [[String]] {
        self == .system ? [["system", "status"], ["system", "version"], ["system", "df"], ["system", "property", "list"]] : []
    }

    var subtitle: ResourceField? {
        switch self {
        case .containers: ResourceField(label: "Image", symbol: "square.3.layers.3d", path: "configuration.image.reference", format: .image)
        case .machines: ResourceField(label: "Image", symbol: "square.3.layers.3d", path: "configuration.image.reference", format: .image)
        case .images: ResourceField(label: "Digest", symbol: "number", path: "id")
        case .volumes: ResourceField(label: "Format", symbol: "internaldrive", path: "configuration.format")
        case .networks: ResourceField(label: "Mode", symbol: "point.3.connected.trianglepath.dotted", path: "configuration.mode")
        case .builder: ResourceField(label: "Image", symbol: "square.3.layers.3d", path: "configuration.image.reference", format: .image)
        case .clusters, .registries, .dnsDomains, .system: nil
        }
    }

    var fields: [ResourceField] {
        switch self {
        case .containers, .machines, .builder: [
            ResourceField(label: "IP address", symbol: "network", path: "status.networks.0.ipv4Address", width: 160),
            ResourceField(label: "CPUs", symbol: "cpu", path: "configuration.resources.cpus", width: 56),
            ResourceField(label: "Memory", symbol: "memorychip", path: "configuration.resources.memoryInBytes", format: .bytes, width: 84)
        ]
        case .images: [
            ResourceField(label: "Created", symbol: "clock", path: "configuration.creationDate", format: .date)
        ]
        case .volumes: [
            ResourceField(label: "Size", symbol: "externaldrive", path: "configuration.sizeInBytes", format: .bytes, width: 90),
            ResourceField(label: "Created", symbol: "clock", path: "configuration.creationDate", format: .date)
        ]
        case .networks: [
            ResourceField(label: "IPv4 subnet", symbol: "point.3.filled.connected.trianglepath.dotted", path: "status.ipv4Subnet", width: 160),
            ResourceField(label: "Gateway", symbol: "arrow.triangle.branch", path: "status.ipv4Gateway", width: 140)
        ]
        case .clusters, .registries, .dnsDomains, .system: []
        }
    }

    /// Paths tried in order to identify a record; images are addressed by reference, not digest.
    var idPaths: [String] {
        let common = ["id", "configuration.id", "configuration.name", "name", "hostname", "server", "domain"]
        return self == .images ? ["configuration.name"] + common : common
    }

    var itemActions: [ResourceAction] {
        switch self {
        case .containers: [
            ResourceAction(title: "Start", symbol: "play.fill", path: ["start"], subject: .argument("container-id"), behavior: .immediate, availability: .stopped),
            ResourceAction(title: "Stop", symbol: "stop.fill", path: ["stop"], subject: .argument("container-ids"), behavior: .immediate, availability: .running),
            ResourceAction(title: "Open Shell", symbol: "apple.terminal", path: ["exec"], subject: .argument("container-id"), behavior: .immediate, availability: .running,
                           options: ["--interactive": [], "--tty": []], arguments: ["arguments": "sh"]),
            ResourceAction(title: "Run Command…", symbol: "terminal", path: ["exec"], subject: .argument("container-id"), availability: .running),
            ResourceAction(title: "Follow Logs…", symbol: "text.alignleft", path: ["logs"], subject: .argument("container-id"), options: ["--follow": []]),
            ResourceAction(title: "Live Stats…", symbol: "chart.xyaxis.line", path: ["stats"], subject: .argument("containers"), availability: .running),
            ResourceAction(title: "Copy Files…", symbol: "doc.on.doc", path: ["copy"], subject: .argumentPrefix("source")),
            ResourceAction(title: "Commit to Image…", symbol: "square.and.arrow.down.on.square", path: ["commit"], subject: .argument("id")),
            ResourceAction(title: "Export Filesystem…", symbol: "archivebox", path: ["export"], subject: .argument("id")),
            ResourceAction(title: "Send Signal…", symbol: "bolt", path: ["kill"], subject: .argument("container-ids"), availability: .running),
            ResourceAction(title: "Clean", symbol: "sparkles", path: ["clean"], subject: .argument("container-ids"), behavior: .immediate, availability: .running),
            ResourceAction(title: "Delete", symbol: "trash", path: ["delete"], subject: .argument("container-ids"), behavior: .immediate, availability: .stopped)
        ]
        case .machines: [
            ResourceAction(title: "Open Shell", symbol: "apple.terminal", path: ["machine", "run"], subject: .option("--name"), behavior: .immediate),
            ResourceAction(title: "Run Command…", symbol: "terminal", path: ["machine", "run"], subject: .option("--name")),
            ResourceAction(title: "Stop", symbol: "stop.fill", path: ["machine", "stop"], subject: .argument("id"), behavior: .immediate, availability: .running),
            ResourceAction(title: "Make Default", symbol: "star", path: ["machine", "set-default"], subject: .argument("id"), behavior: .immediate),
            ResourceAction(title: "Settings…", symbol: "slider.horizontal.3", path: ["machine", "set"], subject: .option("--name")),
            ResourceAction(title: "Logs…", symbol: "text.alignleft", path: ["machine", "logs"], subject: .argument("id")),
            ResourceAction(title: "Delete", symbol: "trash", path: ["machine", "delete"], subject: .argument("id"), behavior: .immediate)
        ]
        case .clusters: [
            ResourceAction(title: "Write Kubeconfig…", symbol: "doc.badge.gearshape", path: ["cluster", "write-config"], subject: .option("--name")),
            ResourceAction(title: "Delete", symbol: "trash", path: ["cluster", "delete"], subject: .option("--name"), behavior: .immediate)
        ]
        case .images: [
            ResourceAction(title: "Run…", symbol: "play.fill", path: ["run"], subject: .argument("image"), behavior: .quickRun),
            ResourceAction(title: "Run with Options…", symbol: "slider.horizontal.3", path: ["run"], subject: .argument("image")),
            ResourceAction(title: "Create Machine…", symbol: "desktopcomputer", path: ["machine", "create"], subject: .argument("image")),
            ResourceAction(title: "Tag…", symbol: "tag", path: ["image", "tag"], subject: .argument("source")),
            ResourceAction(title: "Push…", symbol: "arrow.up.circle", path: ["image", "push"], subject: .argument("reference")),
            ResourceAction(title: "Save to Archive…", symbol: "archivebox", path: ["image", "save"], subject: .argument("references")),
            ResourceAction(title: "Delete", symbol: "trash", path: ["image", "delete"], subject: .argument("images"), behavior: .immediate)
        ]
        case .volumes: [
            ResourceAction(title: "Delete", symbol: "trash", path: ["volume", "delete"], subject: .argument("names"), behavior: .immediate)
        ]
        case .networks: [
            ResourceAction(title: "Delete", symbol: "trash", path: ["network", "delete"], subject: .argument("network-names"), behavior: .immediate)
        ]
        case .registries: [
            ResourceAction(title: "Log Out", symbol: "rectangle.portrait.and.arrow.right", path: ["registry", "logout"], subject: .argument("registry"), behavior: .immediate)
        ]
        case .dnsDomains: [
            ResourceAction(title: "Delete", symbol: "trash", path: ["system", "dns", "delete"], subject: .argument("domain-name"), behavior: .immediate)
        ]
        case .builder, .system: []
        }
    }

    var collectionActions: [ResourceAction] {
        switch self {
        case .containers: [
            ResourceAction(title: "New Container…", symbol: "plus", path: ["run"], behavior: .quickRun),
            ResourceAction(title: "Run with Options…", symbol: "slider.horizontal.3", path: ["run"]),
            ResourceAction(title: "Create Without Starting…", symbol: "shippingbox", path: ["create"]),
            ResourceAction(title: "Stop All", symbol: "stop.fill", path: ["stop"], behavior: .immediate, options: ["--all": []], confirms: true),
            ResourceAction(title: "Remove Stopped", symbol: "trash", path: ["prune"], behavior: .immediate)
        ]
        case .machines: [ResourceAction(title: "New Machine…", symbol: "plus", path: ["machine", "create"])]
        case .clusters: [ResourceAction(title: "New Cluster…", symbol: "plus", path: ["cluster", "create"])]
        case .images: [
            ResourceAction(title: "Pull Image…", symbol: "arrow.down.circle", path: ["image", "pull"]),
            ResourceAction(title: "Build Image…", symbol: "hammer", path: ["build"]),
            ResourceAction(title: "Load from Archive…", symbol: "archivebox", path: ["image", "load"]),
            ResourceAction(title: "Remove Unused…", symbol: "trash", path: ["image", "prune"])
        ]
        case .volumes: [
            ResourceAction(title: "New Volume…", symbol: "plus", path: ["volume", "create"]),
            ResourceAction(title: "Remove Unused", symbol: "trash", path: ["volume", "prune"], behavior: .immediate)
        ]
        case .networks: [
            ResourceAction(title: "New Network…", symbol: "plus", path: ["network", "create"]),
            ResourceAction(title: "Remove Unused", symbol: "trash", path: ["network", "prune"], behavior: .immediate)
        ]
        case .builder: [
            ResourceAction(title: "Start Builder…", symbol: "play.fill", path: ["builder", "start"]),
            ResourceAction(title: "Stop Builder", symbol: "stop.fill", path: ["builder", "stop"], behavior: .immediate),
            ResourceAction(title: "Delete Builder", symbol: "trash", path: ["builder", "delete"], behavior: .immediate)
        ]
        case .registries: [ResourceAction(title: "Log In…", symbol: "person.badge.key", path: ["registry", "login"])]
        case .dnsDomains: [ResourceAction(title: "New Domain…", symbol: "plus", path: ["system", "dns", "create"])]
        case .system: [
            ResourceAction(title: "Start System", symbol: "power", path: ["system", "start"], behavior: .immediate),
            ResourceAction(title: "Stop System", symbol: "stop.fill", path: ["system", "stop"], behavior: .immediate),
            ResourceAction(title: "System Logs…", symbol: "text.alignleft", path: ["system", "logs"]),
            ResourceAction(title: "Set Kernel…", symbol: "gearshape", path: ["system", "kernel", "set"])
        ]
        }
    }

    /// Every CLI command this resource's view can run.
    var commandPaths: [[String]] {
        [listCommand?.path, inspectCommand].compactMap { $0 } + readCommands
            + (itemActions + collectionActions).map(\.path)
    }

    static var coveredCommandIDs: Set<String> {
        Set(allCases.flatMap(\.commandPaths).map { $0.joined(separator: " ") })
    }

    /// Decodes list output. Returns nil when records lack identifiers, so callers can fall back to `--quiet`.
    func items(fromJSON output: String) throws -> [ResourceItem]? {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        let records: [JSONValue] = switch value {
        case .array(let values): values
        case .null: []
        default: [value]
        }
        var items: [ResourceItem] = []
        for record in records {
            guard let id = idPaths.lazy.compactMap({ record[$0]?.text }).first else { return nil }
            items.append(ResourceItem(id: id, record: record))
        }
        return items
    }

    static func items(fromQuiet output: String) -> [ResourceItem] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ResourceItem(id: $0, record: .null) }
    }
}
