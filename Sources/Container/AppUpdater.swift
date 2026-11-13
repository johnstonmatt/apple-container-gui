import AppKit
import SwiftUI

struct AppRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable { let name: String; let browserDownloadUrl: URL }
    let tagName: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    var notesURL: URL { URL(string: "https://github.com/johnstonmatt/apple-container-gui/releases/tag/\(tagName)")! }

    func downloadURL() throws -> URL {
        guard !draft, !prerelease, AppVersion(version) != nil,
              let asset = assets.first(where: { $0.name == "Container-\(tagName)-macos-arm64.zip" }),
              asset.browserDownloadUrl.scheme == "https", asset.browserDownloadUrl.host == "github.com",
              asset.browserDownloadUrl.path.hasPrefix("/johnstonmatt/apple-container-gui/releases/download/") else {
            throw CLIError(message: "This release has no supported Container download.")
        }
        return asset.browserDownloadUrl
    }
}

struct AppVersion: Comparable {
    let parts: [Int]
    init?(_ value: String) {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              components.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = components.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

@MainActor @Observable
final class AppUpdater {
    var presented = false
    private(set) var checking = false
    private(set) var installing = false
    private(set) var release: AppRelease?
    var message: String?
    let currentVersion: String
    private let loadRelease: @Sendable () async throws -> AppRelease
    static let resultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Container/update-result.txt")

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build",
         loadRelease: @escaping @Sendable () async throws -> AppRelease = AppUpdater.fetchRelease) {
        self.currentVersion = currentVersion
        self.loadRelease = loadRelease
    }

    func restoreResult() {
        if let result = try? String(contentsOf: Self.resultURL, encoding: .utf8) {
            message = result
            presented = true
            try? FileManager.default.removeItem(at: Self.resultURL)
        }
    }

    func check() async {
        presented = true
        guard !checking, !installing else { return }
        checking = true
        release = nil
        message = nil
        defer { checking = false }
        do {
            guard let current = AppVersion(currentVersion) else {
                throw CLIError(message: "Run the packaged Container.app to check for updates.")
            }
            let latest = try await loadRelease()
            _ = try latest.downloadURL()
            guard let version = AppVersion(latest.version) else { throw CLIError(message: "Invalid release version.") }
            if version > current { release = latest }
            else { message = "Container \(currentVersion) is up to date." }
        } catch { message = error.localizedDescription }
    }

    nonisolated static func fetchRelease() async throws -> AppRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/johnstonmatt/apple-container-gui/releases/latest")!)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Container-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CLIError(message: "Couldn’t check GitHub for a release. Try again later.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AppRelease.self, from: data)
    }

    func install(store: Store) async {
        guard !checking, !installing, !store.busy, let release else { return }
        installing = true
        message = "Downloading and verifying Container \(release.version)…"
        defer { installing = false }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Container-update-\(UUID().uuidString)")
        var handedOff = false
        defer { if !handedOff { try? FileManager.default.removeItem(at: work) } }
        do {
            let currentApp = Bundle.main.bundleURL
            guard currentApp.pathExtension == "app", currentApp.lastPathComponent == "Container.app",
                  FileManager.default.isWritableFile(atPath: currentApp.deletingLastPathComponent().path),
                  let helper = Bundle.main.url(forResource: "update", withExtension: "zsh") else {
                throw CLIError(message: "Move Container.app to a writable Applications folder before updating.")
            }
            // Pin downloads to the same Developer ID team as the running app.
            let signature = try await tool("/usr/bin/codesign", ["-dv", "--verbose=4", currentApp.path])
            guard let team = signature.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") })?.dropFirst("TeamIdentifier=".count),
                  team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw CLIError(message: "In-app installation requires a Developer ID signed build. Download a signed release from GitHub.")
            }
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var request = URLRequest(url: try release.downloadURL())
            request.timeoutInterval = 300
            let (download, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: download) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CLIError(message: "The release download failed.") }
            let archive = work.appendingPathComponent("release.zip")
            try FileManager.default.moveItem(at: download, to: archive)
            _ = try await tool("/usr/bin/ditto", ["-x", "-k", archive.path, work.path])
            let app = work.appendingPathComponent("Container.app")
            let requirement = "anchor apple generic and identifier \"dev.johnstonmatt.container\" and certificate leaf[subject.OU] = \"\(team)\""
            _ = try await tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, app.path])
            _ = try await tool("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
            guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "dev.johnstonmatt.container",
                  bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
                  FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/install.zsh").path) else {
                throw CLIError(message: "The downloaded app doesn’t match this release or lacks its installer.")
            }
            guard !store.operation.running else { throw CLIError(message: "Finish the active operation before installing.") }
            let copiedHelper = work.appendingPathComponent("update.zsh")
            try FileManager.default.copyItem(at: helper, to: copiedHelper)
            try FileManager.default.createDirectory(at: Self.resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [copiedHelper.path, String(ProcessInfo.processInfo.processIdentifier), work.path, currentApp.path, Self.resultURL.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            handedOff = true
            NSApplication.shared.terminate(nil)
        } catch { message = "Update failed: \(error.localizedDescription)" }
    }

    private func tool(_ executable: String, _ arguments: [String]) async throws -> String {
        let result = try await CommandRunner.run(executable: executable, arguments: arguments)
        guard result.exitCode == 0 else { throw CLIError(message: "\((executable as NSString).lastPathComponent) failed: \(result.display)") }
        return result.stdout + result.stderr
    }
}

struct AppUpdateView: View {
    @Bindable var store: Store
    var updater: AppUpdater { store.updater }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Container Updates").font(.title2.bold())
            Text("Installed version: \(updater.currentVersion)").foregroundStyle(.secondary)
            if updater.checking || updater.installing { ProgressView().controlSize(.small) }
            if let release = updater.release {
                Text("Container \(release.version) is available.").font(.headline)
                ScrollView { Text(release.body ?? "No release notes provided.").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 220)
                Link("View release on GitHub", destination: release.notesURL)
            }
            if let message = updater.message { Text(message).textSelection(.enabled) }
            Text("Updates the Container app. Apple’s container CLI is managed separately. Terminal sessions remain managed by Terminal.")
                .font(.caption).foregroundStyle(.secondary)
            if store.busy && !updater.installing { Text("Finish or cancel the active operation before installing.").font(.callout) }
            HStack {
                Button("Close") { updater.presented = false }.keyboardShortcut(.cancelAction).disabled(updater.installing)
                Spacer()
                Button("Check Again") { Task { await updater.check() } }.disabled(updater.checking || updater.installing)
                if updater.release != nil {
                    Button("Install and Relaunch") { Task { await updater.install(store: store) } }
                        .buttonStyle(.borderedProminent).disabled(store.busy || updater.checking)
                }
            }
        }.padding(24).frame(width: 520)
        .interactiveDismissDisabled(updater.installing)
    }
}
