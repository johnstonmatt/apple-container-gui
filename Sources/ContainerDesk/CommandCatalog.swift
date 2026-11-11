import Foundation

struct HelpPage: Codable, Sendable {
    let path: [String]
    let help: String
}

struct CommandOption: Identifiable, Hashable, Sendable {
    let flag: String
    let valueName: String?
    var description: String
    var id: String { flag }
    var takesValue: Bool { valueName != nil }
}

struct CommandArgument: Identifiable, Hashable, Sendable {
    let name: String
    let optional: Bool
    let repeated: Bool
    var description: String
    var id: String { name }
}

struct CommandDefinition: Identifiable, Sendable {
    let path: [String]
    let summary: String
    let usage: String
    let help: String
    let options: [CommandOption]
    let arguments: [CommandArgument]
    let children: [String]
    var id: String { path.joined(separator: " ") }
    var group: String {
        guard let first = path.first else { return "Other" }
        return ["image", "registry", "machine", "volume", "network", "system", "cluster", "builder", "build"].contains(first)
            ? first.capitalized : "Container"
    }
    var destructive: Bool {
        path.contains(where: { ["delete", "prune", "clean", "kill"].contains($0) }) || path == ["system", "stop"]
    }
    var administrator: Bool { path.starts(with: ["system", "dns"]) && ["create", "delete"].contains(path.last ?? "") }

    static func parse(_ page: HelpPage) -> Self {
        let lines = page.help.components(separatedBy: .newlines)
        let usage = lines.first { $0.hasPrefix("USAGE:") }.map { String($0.dropFirst(7)) } ?? ""
        var section = ""
        var summary = ""
        var options: [CommandOption] = []
        var arguments: [CommandArgument] = []
        var children: [String] = []
        for line in lines {
            if line.hasPrefix("OVERVIEW:") { summary = String(line.dropFirst(10)); section = "overview"; continue }
            if !line.isEmpty && !line.hasPrefix(" ") && line.hasSuffix(":") { section = line; continue }
            if line.hasPrefix("USAGE:") { section = ""; continue }
            if section == "overview", !line.isEmpty { summary += " " + line.trimmingCharacters(in: .whitespaces) }
            if section.hasSuffix("SUBCOMMANDS:"), line.hasPrefix("  "), !line.hasPrefix("   ") {
                if let first = line.split(whereSeparator: { $0 == " " || $0 == "," }).first,
                   first.first?.isLowercase == true { children.append(String(first)) }
            }
            if section.hasSuffix("OPTIONS:") {
                if line.hasPrefix("  -") {
                    // ArgumentParser aligns descriptions with two or more spaces.
                    let trimmed = String(line.dropFirst(2))
                    let split = trimmed.range(of: #"\s{2,}"#, options: .regularExpression)
                    let declaration = split.map { String(trimmed[..<$0.lowerBound]) } ?? trimmed
                    let description = split.map { String(trimmed[$0.upperBound...]) } ?? ""
                    let flags = matches(#"--?[a-zA-Z][a-zA-Z0-9-]*"#, in: declaration)
                    let placeholder = matches(#"<[^>]+>"#, in: declaration).first.map { String($0.dropFirst().dropLast()) }
                    // Opposing boolean flags are independent choices, not aliases.
                    let selected = declaration.contains("/") ? flags : [flags.first(where: { $0.hasPrefix("--") }) ?? flags.first ?? ""]
                    for flag in selected where !["", "--help", "-h", "--version"].contains(flag) {
                        options.append(.init(flag: flag, valueName: placeholder, description: description))
                    }
                } else if line.hasPrefix("    "), !options.isEmpty {
                    options[options.count - 1].description += " " + line.trimmingCharacters(in: .whitespaces)
                }
            }
            if section == "ARGUMENTS:" {
                if line.hasPrefix("  <"), let end = line.firstIndex(of: ">") {
                    let name = String(line[line.index(line.startIndex, offsetBy: 3)..<end])
                    let token = "<\(name)>"
                    arguments.append(.init(name: name, optional: usage.contains("[\(token)"),
                        repeated: usage.contains("\(token) ..."),
                        description: line[line.index(after: end)...].trimmingCharacters(in: .whitespaces)))
                } else if line.hasPrefix("    "), !arguments.isEmpty {
                    arguments[arguments.count - 1].description += " " + line.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return .init(path: page.path, summary: summary, usage: usage, help: page.help,
                     options: options, arguments: arguments, children: children)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}

enum CommandCatalog {
    static func bundledPages() throws -> [HelpPage] {
        guard let url = Bundle.module.url(forResource: "commands", withExtension: "json") else {
            throw CLIError(message: "The bundled command catalog is missing.")
        }
        return try JSONDecoder().decode([HelpPage].self, from: Data(contentsOf: url))
    }
    static func definitions(_ pages: [HelpPage]) -> [CommandDefinition] {
        pages.map(CommandDefinition.parse).filter { !$0.path.isEmpty && $0.children.isEmpty }.sorted { $0.id < $1.id }
    }

    static func discover(using cli: ContainerCLI) async throws -> [HelpPage] {
        var queue: [[String]] = [[]]
        var seen = Set<String>()
        var pages: [HelpPage] = []
        while !queue.isEmpty {
            try Task.checkCancellation()
            let path = queue.removeFirst()
            guard seen.insert(path.joined(separator: " ")).inserted else { continue }
            guard seen.count <= 500 else { throw CLIError(message: "The command tree exceeds 500 entries.") }
            let help = try await cli.run(path + ["--help"])
            let page = HelpPage(path: path, help: help)
            pages.append(page)
            queue += CommandDefinition.parse(page).children.map { path + [$0] }
        }
        return pages
    }
}

/// Shell-like quoting only. No expansion, substitution, pipes, or execution.
enum ArgumentWords {
    static func parse(_ text: String) throws -> [String] {
        var words: [String] = []; var current = ""; var quote: Character?; var escaped = false; var started = false
        for char in text {
            if escaped { current.append(char); escaped = false; started = true; continue }
            if char == "\\", quote != "'" { escaped = true; started = true; continue }
            if let q = quote {
                if char == q { quote = nil } else { current.append(char) }
                continue
            }
            if char == "'" || char == "\"" { quote = char; started = true }
            else if char.isWhitespace {
                if started { words.append(current); current = ""; started = false }
            } else { current.append(char); started = true }
        }
        guard quote == nil && !escaped else { throw CLIError(message: "Close the quote or complete the escape in the arguments field.") }
        if started { words.append(current) }
        return words
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// Quotes only when needed, for showing commands to people.
    static func display(_ value: String) -> String {
        value.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) == nil ? quote(value) : value
    }
}

struct CommandDraft {
    var enabled = Set<String>()
    var values: [String: [String]] = [:]
    var positionals: [String: String] = [:]
    var additional = ""
    var directory = FileManager.default.homeDirectoryForCurrentUser.path
    var terminal = false
    var password = ""

    func arguments(for command: CommandDefinition) throws -> [String] {
        var result = command.path
        for option in command.options where enabled.contains(option.flag) {
            if option.takesValue {
                let entries = values[option.flag] ?? [""]
                guard !entries.isEmpty else { throw CLIError(message: "Enter a value for \(option.flag).") }
                for value in entries { result += [option.flag, value] }
            } else { result.append(option.flag) }
        }
        result += try ArgumentWords.parse(additional)
        if command.path == ["registry", "login"], !terminal {
            guard !password.isEmpty else { throw CLIError(message: "Enter the registry password or token.") }
            guard enabled.contains("--username"), !(values["--username"]?.first ?? "").isEmpty else {
                throw CLIError(message: "Enter a registry username.")
            }
            if !result.contains("--password-stdin") { result.append("--password-stdin") }
        }
        if command.path == ["system", "start"], !result.contains("--enable-kernel-install"), !result.contains("--disable-kernel-install") {
            result.append("--enable-kernel-install")
        }
        for argument in command.arguments {
            let value = positionals[argument.name] ?? ""
            if value.isEmpty {
                if !argument.optional { throw CLIError(message: "Enter \(argument.name).") }
                continue
            }
            let words = argument.repeated ? try ArgumentWords.parse(value) : [value]
            if !argument.optional && words.isEmpty { throw CLIError(message: "Enter \(argument.name).") }
            result += words
        }
        guard !result.contains(where: { $0.contains("\0") }) else { throw CLIError(message: "Arguments cannot contain a NUL character.") }
        if !terminal && ["export", "image save"].contains(command.id) {
            guard let index = result.firstIndex(where: { ["--output", "-o"].contains($0) }),
                  result.indices.contains(index + 1), !["", "-"].contains(result[index + 1]) else {
                throw CLIError(message: "Choose an output file for the archive.")
            }
        }
        if !terminal && command.id == "image load" && !result.contains("--input") && !result.contains("-i") {
            throw CLIError(message: "Choose the archive input file.")
        }
        return result
    }

    func requiresTerminal(for command: CommandDefinition) -> Bool {
        let extras = (try? ArgumentWords.parse(additional)) ?? []
        return terminal || command.administrator || command.path == ["machine", "run"] ||
        extras.contains(where: { ["-i", "-t", "-it", "-ti", "--tty", "--interactive"].contains($0) }) ||
        enabled.contains("--tty") || enabled.contains("--interactive") ||
        (command.path == ["registry", "login"] && password.isEmpty)
    }
}
