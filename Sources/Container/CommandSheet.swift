import SwiftUI
import AppKit

struct CommandSheet: View {
    @Bindable var store: Store
    let request: CommandRequest
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CommandDraft
    @State private var optionFilter = ""
    @State private var error: String?
    @State private var confirm = false
    @State private var showHelp = false

    init(store: Store, request: CommandRequest) {
        self.store = store
        self.request = request
        _draft = State(initialValue: request.draft)
    }

    var command: CommandDefinition { request.command }
    var session: OperationSession { store.operation }
    var effectiveDraft: CommandDraft {
        var effective = draft
        effective.terminal = draft.requiresTerminal(for: command)
        return effective
    }
    var finished: Bool { [.succeeded, .openedInTerminal].contains(session.phase) }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            Divider()
            form.layoutPriority(1)
            if session.phase != .idle {
                Divider()
                output.frame(height: 210)
            }
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 640, idealWidth: 720, maxWidth: 1100, minHeight: 520, idealHeight: 700, maxHeight: 1400)
        .onAppear { session.clear() }
        .interactiveDismissDisabled(session.running)
        .confirmationDialog("\(request.label)?", isPresented: $confirm) {
            Button(request.title.replacingOccurrences(of: "…", with: ""), role: .destructive) { launch() }
        } message: { Text("This can remove data or stop running workloads, and can’t be undone.") }
        .sheet(isPresented: $showHelp) { helpSheet }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                SymbolTile(symbol: request.symbol, tint: command.destructive ? .red : .accentColor, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title.replacingOccurrences(of: "…", with: "")).font(.title2.weight(.semibold))
                    Text([request.subject, command.summary].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Button("CLI Help", systemImage: "questionmark.circle") { showHelp = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.title3)
                    .help("Show the full CLI help for \(command.id)")
            }
            preview
            if let error { InlineError(message: error) }
        }
    }

    var preview: some View {
        let result = Result { try effectiveDraft.arguments(for: command) }
        let words = (try? result.get()) ?? command.path
        let text = (command.administrator ? "sudo " : "") + "container " + words.map(ArgumentWords.display).joined(separator: " ")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$").foregroundStyle(.tertiary)
                Text(text).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Copy Command", systemImage: "doc.on.doc") { copyToPasteboard(text) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy command")
            }
            .font(.system(.callout, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if case .failure(let failure) = result {
                Label(failure.localizedDescription, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var form: some View {
        Form {
            if !command.arguments.isEmpty {
                Section("Arguments") {
                    ForEach(command.arguments) { argument in argumentField(argument) }
                }
            }
            if command.id == "registry login" && !draft.terminal {
                Section {
                    SecureField("Password or token", text: $draft.password, prompt: Text("Required"))
                } header: { Text("Credentials") } footer: {
                    note("Sent through standard input — never added to arguments or saved to disk. Also enable --username below.")
                }
            }
            if !command.options.isEmpty {
                Section {
                    if command.options.count > 8 {
                        TextField("Filter", text: $optionFilter, prompt: Text("Filter \(command.options.count) options"))
                            .labelsHidden()
                    }
                    ForEach(visibleOptions) { option in optionField(option) }
                } header: {
                    HStack {
                        Text("Options")
                        Spacer()
                        if !draft.enabled.isEmpty {
                            Text("\(draft.enabled.count) enabled").foregroundStyle(.secondary)
                            Button("Reset") { draft.enabled = []; draft.values = [:] }.buttonStyle(.link)
                        }
                    }
                }
            }
            Section {
                LabeledContent("Working directory") {
                    HStack(spacing: 6) {
                        TextField("Working directory", text: $draft.directory).labelsHidden()
                        Button("Choose…") { chooseFile(directory: true) { draft.directory = $0 } }
                    }
                }
                Toggle(isOn: $draft.terminal) {
                    Text("Run in Terminal")
                    Text("Use a real TTY for shells, interactive input, and prompts.")
                }
                TextField("Additional arguments", text: $draft.additional, prompt: Text("--flag value"))
            } header: { Text("Execution") } footer: { executionNotes }
        }
        .formStyle(.grouped)
        .disabled(session.running || store.busy)
    }

    var executionNotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            note("Quote values that contain spaces. Shell substitutions and operators are passed literally.")
            if command.administrator {
                note("Opens in Terminal with sudo so you can authorize it there.")
            } else if draft.requiresTerminal(for: command) {
                note("Opens in Terminal. Refresh when it finishes.")
            }
            if command.id == "system start" {
                note("Installs the recommended kernel if missing unless you enable --disable-kernel-install.")
            }
        }
    }

    func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    var visibleOptions: [CommandOption] {
        command.options.filter {
            optionFilter.isEmpty || "\($0.flag) \($0.description)".localizedCaseInsensitiveContains(optionFilter)
        }
    }

    func argumentField(_ argument: CommandArgument) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(argument.name, text: Binding(get: { draft.positionals[argument.name] ?? "" },
                                                       set: { draft.positionals[argument.name] = $0 }),
                          prompt: Text(argument.repeated ? "Values separated by spaces" : argument.optional ? "Optional" : "Required"))
                    .labelsHidden()
                if argument.name.contains("dir") || argument.name.contains("path") || argument.name.contains("file")
                    || (command.id == "copy" && ["source", "destination"].contains(argument.name)) {
                    Button("Choose…") { chooseFile(directory: argument.name.contains("dir")) { draft.positionals[argument.name] = $0 } }
                }
            }
            .frame(minWidth: 220)
        } label: {
            Text(argument.name).font(.system(.body, design: .monospaced))
            if !argument.description.isEmpty { Text(argument.description) }
        }
    }

    @ViewBuilder func optionField(_ option: CommandOption) -> some View {
        Toggle(isOn: Binding(get: { draft.enabled.contains(option.flag) }, set: { enabled in
            if enabled { draft.enabled.insert(option.flag) } else { draft.enabled.remove(option.flag) }
        })) {
            Text(option.flag).font(.system(.body, design: .monospaced))
            if !option.description.isEmpty { Text(option.description) }
        }
        if option.takesValue && draft.enabled.contains(option.flag) {
            let entries = draft.values[option.flag] ?? [""]
            ForEach(entries.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                    TextField(option.valueName ?? "Value", text: Binding(get: {
                        let values = draft.values[option.flag] ?? [""]
                        return index < values.count ? values[index] : ""
                    }, set: { value in
                        var values = draft.values[option.flag] ?? [""]
                        if index < values.count { values[index] = value }
                        draft.values[option.flag] = values
                    }), prompt: Text(option.valueName ?? "value"))
                    .labelsHidden()
                    if ["--input", "--output", "--file", "--env-file", "--binary", "--tar", "--kubeconfig"].contains(option.flag) {
                        Button("Choose…") { chooseFile(save: ["--output", "--kubeconfig"].contains(option.flag)) { value in
                            var values = draft.values[option.flag] ?? [""]
                            values[index] = value
                            draft.values[option.flag] = values
                        } }
                    }
                    if entries.count > 1 {
                        Button("Remove Value", systemImage: "minus.circle") { draft.values[option.flag]?.remove(at: index) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).help("Remove value")
                    }
                    if index == entries.count - 1 {
                        Button("Add Value", systemImage: "plus.circle") { draft.values[option.flag] = entries + [""] }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help("Add another value, for options that accept repeated values")
                    }
                }
            }
        }
    }

    var output: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                PhaseLabel(session: session)
                Spacer()
                Group {
                    Button("Copy Output", systemImage: "doc.on.doc") { copyToPasteboard(session.output) }
                        .disabled(session.output.isEmpty)
                    Button("Save Output…", systemImage: "square.and.arrow.down") { saveOutput() }
                        .disabled(session.output.isEmpty)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            ConsoleView(text: session.output, placeholder: "Waiting for output…", follows: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .help("Shows the most recent 2 MB per output stream. Stopping ends the CLI process; it does not undo changes.")
    }

    var footer: some View {
        HStack {
            Text(command.destructive ? "This operation can remove data." : "")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if session.running {
                Button("Stop", systemImage: "stop.fill", role: .destructive) { session.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(finished ? "Run Again" : "Cancel") {
                    if finished { launchConfirmingIfNeeded() } else { dismiss() }
                }
                .keyboardShortcut(finished ? nil : .cancelAction)
                Button(finished ? "Done" : draft.requiresTerminal(for: command) ? "Open in Terminal" : "Run") {
                    if finished { dismiss() } else { launchConfirmingIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
                .tint(command.destructive && !finished ? .red : .accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(!finished && (store.busy || ContainerCLI.executable == nil))
            }
        }
        .controlSize(.large)
    }

    var helpSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("container \(command.id) --help").font(.system(.headline, design: .monospaced))
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(command.help) }
            }
            ConsoleView(text: command.help, placeholder: "No help available.", wraps: true)
            HStack { Spacer(); Button("Done") { showHelp = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 720, height: 560)
    }

    func launchConfirmingIfNeeded() {
        if command.destructive || request.confirms { confirm = true } else { launch() }
    }

    func launch() {
        guard let executable = ContainerCLI.executable else { return }
        do {
            let effective = effectiveDraft
            let arguments = try effective.arguments(for: command)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: draft.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CLIError(message: "Choose an existing working directory.")
            }
            error = nil
            if effective.terminal {
                Task {
                    do {
                        try await TerminalScript.open(executable: executable, arguments: arguments,
                            directory: effective.directory, administrator: command.administrator)
                        session.phase = .openedInTerminal
                    } catch { self.error = error.localizedDescription }
                }
            } else {
                let input = command.id == "registry login" ? draft.password + "\n" : nil
                session.start(executable: executable, arguments: arguments, directory: draft.directory, input: input) {
                    await store.refresh()
                }
                draft.password = ""
            }
        } catch { self.error = error.localizedDescription }
    }

    func chooseFile(directory: Bool = false, save: Bool = false, completion: (String) -> Void) {
        if save {
            let panel = NSSavePanel()
            if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = directory
            panel.canChooseFiles = !directory
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
        }
    }

    func saveOutput() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "container-output.txt"
        if panel.runModal() == .OK, let url = panel.url {
            do { try session.output.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct PhaseLabel: View {
    let session: OperationSession

    var body: some View {
        HStack(spacing: 6) {
            switch session.phase {
            case .idle: Image(systemName: "terminal").foregroundStyle(.secondary)
            case .running: ProgressView().controlSize(.small)
            case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
            case .openedInTerminal: Image(systemName: "apple.terminal").foregroundStyle(.tint)
            }
            Text(session.status).font(.callout.weight(.medium)).lineLimit(1)
        }
    }
}
