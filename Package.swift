// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Container",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Container", targets: ["Container"])],
    targets: [
        .executableTarget(name: "Container", resources: [.process("Resources")]),
        .testTarget(name: "ContainerTests", dependencies: ["Container"])
    ]
)
