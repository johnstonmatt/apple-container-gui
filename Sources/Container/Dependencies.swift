import Foundation

enum DependencyState: Equatable, Sendable {
    case checking
    case missingCLI
    case serviceStopped
    case missingKernel(path: String)
    case unavailable(String)
    case ready

    var title: String {
        switch self {
        case .checking: "Checking dependencies…"
        case .missingCLI: "Apple container isn’t installed"
        case .serviceStopped: "The container system is stopped"
        case .missingKernel: "The Linux kernel is missing"
        case .unavailable: "Couldn’t verify the container system"
        case .ready: "System ready"
        }
    }

    var shortTitle: String {
        switch self {
        case .checking: "Checking dependencies"
        case .missingCLI: "CLI not installed"
        case .serviceStopped: "System stopped"
        case .missingKernel: "Kernel missing"
        case .unavailable: "System unavailable"
        case .ready: "System ready"
        }
    }

    var message: String {
        switch self {
        case .checking: "Checking the CLI, service, and installed Linux kernel."
        case .missingCLI: "Install Apple’s container package, then check again. Container looks in /usr/local/bin, /opt/homebrew/bin, and its PATH, or you can choose a CLI on the System page."
        case .serviceStopped: "Start the container service to continue. First-time setup also downloads the recommended Linux kernel if needed."
        case .missingKernel(let path): "The service is running, but its default Linux kernel is missing or empty. Install the recommended kernel to run containers.\n\nExpected kernel: \(path)"
        case .unavailable(let reason): reason
        case .ready: "The CLI, service, and default Linux kernel are available."
        }
    }

    var recoveryTitle: String? {
        switch self {
        case .serviceStopped: "Start Container System"
        case .missingKernel: "Install Linux Kernel"
        default: nil
        }
    }

    var recoveryArguments: [String]? {
        switch self {
        case .serviceStopped: ["system", "start", "--enable-kernel-install"]
        // The running API server selects the data directory, including custom roots.
        case .missingKernel: ["system", "kernel", "set", "--recommended", "--force"]
        default: nil
        }
    }
}

enum KernelPresence: Equatable {
    case present, missing
    case unreadable(String)

    static func inspect(_ url: URL) -> Self {
        let resolved = url.resolvingSymlinksInPath()
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
            // A dangling symlink can survive resolvingSymlinksInPath on some OS versions.
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink,
               !FileManager.default.fileExists(atPath: resolved.path) { return .missing }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return .unreadable("The default kernel path is not a regular file: \(url.path)")
            }
            guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0 else { return .missing }
            let handle = try FileHandle(forReadingFrom: resolved)
            try handle.close()
            return .present
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return .missing }
            return .unreadable("Couldn’t read the default Linux kernel at \(url.path): \(error.localizedDescription)")
        }
    }
}

enum DependencyChecker {
    private struct Status: Decodable {
        struct Host: Decodable { let architecture: String? }
        struct Paths: Decodable { let appRoot: String? }
        let status: String
        let host: Host?
        let paths: Paths?
    }

    @MainActor
    static func check(
        resolution: ContainerCLI.Resolution = ContainerCLI.resolution,
        readStatus: () async throws -> CommandOutput = {
            try await ContainerCLI().execute(["system", "status", "--format", "json"], timeout: 20)
        }
    ) async -> DependencyState {
        guard resolution.path != nil else {
            // A broken override isn't fixed by installing the package, so don't say it's missing.
            return resolution.requested.map { .unavailable(ContainerCLI.unusableOverrideMessage($0)) } ?? .missingCLI
        }
        do { return evaluate(try await readStatus()) }
        catch { return .unavailable("Couldn’t check the container service: \(error.localizedDescription)") }
    }

    static func evaluate(_ output: CommandOutput, inspectKernel: (URL) -> KernelPresence = KernelPresence.inspect) -> DependencyState {
        guard let status = try? JSONDecoder().decode(Status.self, from: Data(output.stdout.utf8)) else {
            return .unavailable("The CLI didn’t return supported system status JSON. Check that Apple container is up to date.\n\n\(output.display)")
        }
        // The CLI deliberately exits 1 for these structured states.
        if ["unregistered", "not running", "stopped"].contains(status.status) { return .serviceStopped }
        guard output.exitCode == 0, status.status == "running" else {
            return .unavailable("Unexpected container service status: \(status.status).\n\n\(output.display)")
        }
        guard let appRoot = status.paths?.appRoot, appRoot.hasPrefix("/"),
              let architecture = status.host?.architecture,
              ["arm64", "amd64", "x86_64"].contains(architecture) else {
            return .unavailable("The service is running but didn’t report a supported data directory and architecture. Update Apple container, then check again.")
        }
        let kernelArchitecture = architecture == "x86_64" ? "amd64" : architecture
        let kernel = URL(fileURLWithPath: appRoot, isDirectory: true)
            .appendingPathComponent("kernels/default.kernel-\(kernelArchitecture)")
        switch inspectKernel(kernel) {
        case .present: return .ready
        case .missing: return .missingKernel(path: kernel.path)
        case .unreadable(let error): return .unavailable(error)
        }
    }
}
