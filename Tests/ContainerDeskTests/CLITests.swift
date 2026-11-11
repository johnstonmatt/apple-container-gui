import XCTest
@testable import ContainerDesk

final class CLITests: XCTestCase {
    func testDecodesBothStatusSchemas() throws {
        for status in ["\"running\"", "{\"state\":\"running\"}"] {
            let data = Data("[{\"configuration\":{\"id\":\"web\",\"image\":{\"reference\":\"nginx:latest\"}},\"status\":\(status)}]".utf8)
            let records = try JSONDecoder().decode([ContainerRecord].self, from: data)
            XCTAssertEqual(records.first?.id, "web")
            XCTAssertEqual(records.first?.image, "nginx:latest")
            XCTAssertEqual(records.first?.running, true)
        }
    }

    func testRunArgumentsAndValidation() {
        var config = RunConfiguration(image: "nginx:latest", name: "web", port: "8080:80")
        XCTAssertTrue(config.valid)
        XCTAssertEqual(config.arguments, ["run", "--detach", "--cpus", "2", "--memory", "1024M", "--name", "web", "--publish", "127.0.0.1:8080:80", "nginx:latest"])
        for port in ["0:80", "65536:80", "80", "80:", "abc:80"] {
            config.port = port
            XCTAssertFalse(config.valid)
        }
        config.port = ""
        config.name = "bad name"
        XCTAssertFalse(config.valid)
        config.name = "web"
        config.image = "--help"
        XCTAssertFalse(config.valid)
    }

    func testImageReferenceSplitsRepositoryAndTag() {
        let cases: [(String, String, String?)] = [
            ("alpine:latest", "alpine", "latest"),
            ("docker.io/library/alpine:3.20", "docker.io/library/alpine", "3.20"),
            ("localhost:5000/app", "localhost:5000/app", nil),
            ("localhost:5000/app:1.0", "localhost:5000/app", "1.0"),
            ("ghcr.io/owner/app@sha256:abc", "ghcr.io/owner/app", "sha256:abc"),
            ("nginx", "nginx", nil)
        ]
        for (reference, repository, tag) in cases {
            XCTAssertEqual(ImageReference(reference: reference).repository, repository, reference)
            XCTAssertEqual(ImageReference(reference: reference).tag, tag, reference)
        }
    }

    func testImageReferenceDisplayNameDropsImpliedDockerHubPrefix() {
        XCTAssertEqual(ImageReference(reference: "docker.io/library/alpine:latest").displayName, "alpine:latest")
        XCTAssertEqual(ImageReference(reference: "docker.io/owner/app:1").displayName, "owner/app:1")
        XCTAssertEqual(ImageReference(reference: "ghcr.io/owner/app:1").displayName, "ghcr.io/owner/app:1")
    }

    func testFieldValidatorsMatchCompositeValidation() {
        XCTAssertTrue(RunConfiguration.validName(""))
        XCTAssertTrue(RunConfiguration.validName("web-1.api_v2"))
        for name in ["a", "-web", "bad name", String(repeating: "a", count: 64)] {
            XCTAssertFalse(RunConfiguration.validName(name), name)
            XCTAssertFalse(RunConfiguration(image: "alpine", name: name).valid, name)
        }
    }
}
