import Foundation

struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ContainerRecord: Identifiable, Sendable, Decodable {
    let id: String
    let image: String
    let state: String
    var running: Bool { state.lowercased() == "running" }

    private enum Keys: String, CodingKey { case id, configuration, status }
    private struct Configuration: Decodable { let id: String; let image: Image }
    private struct Image: Decodable { let reference: String }
    private struct Status: Decodable { let state: String }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let config = try c.decode(Configuration.self, forKey: .configuration)
        id = config.id
        image = config.image.reference
        if let status = try? c.decode(String.self, forKey: .status) {
            state = status
        } else {
            state = try c.decode(Status.self, forKey: .status).state
        }
    }
}

struct RunConfiguration {
    var image = ""
    var name = ""
    var port = ""
    var cpus = 2
    var memory = 1024

    var valid: Bool { Self.validImage(image) && Self.validName(name) && (port.isEmpty || Self.validPort(port)) }

    static func validImage(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.contains(where: \.isWhitespace)
    }

    static func validName(_ value: String) -> Bool {
        value.isEmpty || value.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]{1,62}$", options: .regularExpression) != nil
    }

    static func validPort(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { Int($0).map { (1...65535).contains($0) } ?? false }
    }

    var arguments: [String] {
        var result = ["run", "--detach", "--cpus", String(cpus), "--memory", "\(memory)M"]
        if !name.isEmpty { result += ["--name", name] }
        if !port.isEmpty { result += ["--publish", "127.0.0.1:\(port)"] }
        return result + [image.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// The same configuration as a draft for the full `run` form.
    var draft: CommandDraft {
        var draft = CommandDraft()
        draft.enabled = ["--detach", "--cpus", "--memory"]
        draft.values = ["--cpus": [String(cpus)], "--memory": ["\(memory)M"]]
        if !name.isEmpty { draft.enabled.insert("--name"); draft.values["--name"] = [name] }
        if !port.isEmpty { draft.enabled.insert("--publish"); draft.values["--publish"] = ["127.0.0.1:\(port)"] }
        draft.positionals["image"] = image.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft
    }
}

struct ImageReference: Identifiable, Hashable, Sendable {
    let reference: String
    var id: String { reference }

    /// The repository without its tag or digest; a registry port such as `localhost:5000` is kept.
    var repository: String { parts.repository }
    /// The tag, or the digest for digest-pinned references.
    var tag: String? { parts.tag }
    /// The reference without the implied Docker Hub prefix, as people usually write it.
    var displayName: String {
        for prefix in ["docker.io/library/", "docker.io/"] where reference.hasPrefix(prefix) {
            return String(reference.dropFirst(prefix.count))
        }
        return reference
    }

    private var parts: (repository: String, tag: String?) {
        if let at = reference.firstIndex(of: "@") {
            return (String(reference[..<at]), String(reference[reference.index(after: at)...]))
        }
        if let colon = reference.lastIndex(of: ":"), reference.lastIndex(of: "/").map({ colon > $0 }) ?? true {
            return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
        }
        return (reference, nil)
    }
}

struct ContainerCLI: Sendable {
    static var executable: String? {
        let paths = ["/usr/local/bin/container", "/opt/homebrew/bin/container"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/container" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func run(_ arguments: [String], timeout: TimeInterval = 60) async throws -> String {
        guard let executable = Self.executable else {
            throw CLIError(message: "Install Apple container to get started, then refresh.")
        }
        let result = try await CommandRunner.run(executable: executable, arguments: arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw CLIError(message: result.display.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }
}
