import XCTest
@testable import ContainerDesk

final class CatalogResourceTests: XCTestCase {
    func testBothSwiftPMBundleLayoutsAfterRelocation() throws {
        for path in ["commands.json", "Contents/Resources/commands.json"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let resources = root.appendingPathComponent("Container.app/Contents/Resources")
            let file = resources.appendingPathComponent("ContainerDesk_ContainerDesk.bundle/\(path)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let pages = [HelpPage(path: ["list"], help: "OVERVIEW: Relocated catalog\nUSAGE: container list")]
            try JSONEncoder().encode(pages).write(to: file)
            let loaded = try CommandCatalog.bundledPages(resourceDirectories: [resources])
            XCTAssertEqual(loaded.first?.help, pages[0].help)
        }
    }

    func testMissingResourceThrowsInsteadOfFallingBackToBuildDirectory() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try CommandCatalog.bundledPages(resourceDirectories: [missing])) { error in
            XCTAssertTrue(error.localizedDescription.contains("bundled command catalog is missing"))
        }
    }

    func testCorruptResourceIsReportedInsteadOfSilentlyUsingAnotherCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("ContainerDesk_ContainerDesk.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("invalid JSON".utf8).write(to: bundle.appendingPathComponent("commands.json"))
        XCTAssertThrowsError(try CommandCatalog.bundledPages(resourceDirectories: [root])) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }
}
