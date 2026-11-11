import SwiftUI

struct RunSheet: View {
    @Bindable var store: Store
    let initialImage: String
    @Environment(\.dismiss) private var dismiss
    @State private var config = RunConfiguration()

    private static let memoryChoices = [(512, "512 MB"), (1024, "1 GB"), (2048, "2 GB"), (4096, "4 GB"), (8192, "8 GB")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(symbol: "shippingbox", title: "New Container",
                        message: "Run an image in its own lightweight Linux virtual machine.")
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 8)
            Form {
                Section {
                    LabeledContent("Image") {
                        HStack(spacing: 6) {
                            TextField("Image", text: $config.image, prompt: Text("nginx:latest")).labelsHidden()
                            if !store.images.isEmpty {
                                Menu {
                                    ForEach(store.images, id: \.self) { image in Button(image) { config.image = image } }
                                } label: { Image(systemName: "square.3.layers.3d") }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Choose a local image")
                            }
                        }
                    }
                    TextField("Name", text: $config.name, prompt: Text("Optional"))
                } footer: {
                    if !RunConfiguration.validName(config.name) {
                        Text("Use 2–63 letters, numbers, periods, hyphens, or underscores, starting with a letter or number.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Resources") {
                    LabeledContent("CPUs") {
                        HStack(spacing: 6) {
                            Text(config.cpus == 1 ? "1 core" : "\(config.cpus) cores").monospacedDigit()
                            Stepper("CPUs", value: $config.cpus, in: 1...16).labelsHidden()
                        }
                    }
                    Picker("Memory", selection: $config.memory) {
                        ForEach(Self.memoryChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                Section {
                    TextField("Publish port", text: $config.port, prompt: Text("8080:80"))
                } header: { Text("Network") } footer: {
                    Text(config.port.isEmpty || RunConfiguration.validPort(config.port)
                         ? "Use host:container. Ports are published on 127.0.0.1 only."
                         : "Enter a host and container port between 1 and 65535, such as 8080:80.")
                        .font(.caption)
                        .foregroundStyle(config.port.isEmpty || RunConfiguration.validPort(config.port) ? Color.secondary : Color.red)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 344)
            if let error = store.error { InlineError(message: error).padding(.horizontal, 24) }
            HStack {
                Button("More Options…") {
                    if let command = store.catalog.command(["run"]) {
                        store.sheet = .command(CommandRequest(command: command, draft: config.draft, title: "Run Container",
                                                              symbol: "shippingbox"))
                    }
                }
                .help("Volumes, environment variables, networks, and every other run option")
                .disabled(store.busy)
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.busy)
                Button(store.busy ? "Starting…" : "Run Container") {
                    Task { if await store.perform(config.arguments, label: "Run \(config.image)") { dismiss() } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!config.valid || store.busy)
            }
            .padding(24)
        }
        .frame(width: 520)
        .onAppear { config.image = initialImage; store.error = nil }
        .onDisappear { store.error = nil }
        .interactiveDismissDisabled(store.busy)
    }
}
