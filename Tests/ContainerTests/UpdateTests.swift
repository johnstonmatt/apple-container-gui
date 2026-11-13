import XCTest
@testable import Container

final class UpdateTests: XCTestCase {
    func testVersionsCompareNumericallyAndRejectMalformedTags() throws {
        XCTAssertGreaterThan(try XCTUnwrap(AppVersion("0.10.0")), try XCTUnwrap(AppVersion("0.9.9")))
        XCTAssertEqual(AppVersion("1.2.3"), AppVersion("1.2.3"))
        for invalid in ["", "v1.2.3", "1.2", "1..3", "1.2.3-rc1", "1.2.3/evil", "-1.2.3", "9999999999999999999999.0.0"] {
            XCTAssertNil(AppVersion(invalid), invalid)
        }
    }

    func testReleaseOnlyAcceptsStableRepositoryAsset() throws {
        func release(draft: Bool = false, prerelease: Bool = false, name: String = "Container-v1.2.3-macos-arm64.zip", url: String = "https://github.com/johnstonmatt/apple-container-gui/releases/download/v1.2.3/Container-v1.2.3-macos-arm64.zip") -> AppRelease {
            AppRelease(tagName: "v1.2.3", body: nil, draft: draft, prerelease: prerelease,
                       assets: [.init(name: name, browserDownloadUrl: URL(string: url)!)])
        }
        XCTAssertEqual(try release().downloadURL().host, "github.com")
        XCTAssertThrowsError(try release(draft: true).downloadURL())
        XCTAssertThrowsError(try release(prerelease: true).downloadURL())
        XCTAssertThrowsError(try release(name: "Other.zip").downloadURL())
        XCTAssertThrowsError(try release(url: "http://github.com/johnstonmatt/apple-container-gui/releases/download/a").downloadURL())
        XCTAssertThrowsError(try release(url: "https://github.com/other/repo/releases/download/a").downloadURL())
        XCTAssertThrowsError(try release(url: "https://evil.example/a").downloadURL())
    }

    private static func release(_ version: String) -> AppRelease {
        AppRelease(tagName: "v\(version)", body: "Release notes", draft: false, prerelease: false,
                   assets: [.init(name: "Container-v\(version)-macos-arm64.zip",
                                  browserDownloadUrl: URL(string: "https://github.com/johnstonmatt/apple-container-gui/releases/download/v\(version)/Container-v\(version)-macos-arm64.zip")!)])
    }

    @MainActor func testCheckOffersOnlyNewerReleases() async {
        for version in ["0.9.0", "1.0.0", "1.1.0"] {
            let updater = AppUpdater(currentVersion: "1.0.0") { Self.release(version) }
            await updater.check()
            XCTAssertEqual(updater.release != nil, version == "1.1.0")
            XCTAssertTrue(updater.presented)
            XCTAssertFalse(updater.checking)
        }
    }

    @MainActor func testFailedCheckAndDevelopmentBuildAreRecoverable() async {
        let updater = AppUpdater(currentVersion: "1.0.0") { throw CLIError(message: "Offline") }
        await updater.check()
        XCTAssertEqual(updater.message, "Offline")
        XCTAssertNil(updater.release)
        XCTAssertFalse(updater.checking)
        let development = AppUpdater(currentVersion: "Development build") {
            XCTFail("Development builds should not fetch releases")
            return Self.release("1.1.0")
        }
        await development.check()
        XCTAssertTrue(development.message?.contains("packaged") == true)
    }

    @MainActor func testInstallDoesNotStartDuringAnOperation() async {
        let updater = AppUpdater(currentVersion: "1.0.0") { Self.release("1.1.0") }
        await updater.check()
        XCTAssertNotNil(updater.release)
        let store = Store()
        store.operation.start(executable: "/bin/sleep", arguments: ["1"], directory: "/tmp") {}
        await updater.install(store: store)
        XCTAssertFalse(updater.installing)
        XCTAssertNil(updater.message)
        store.operation.cancel()
        while store.operation.running { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
