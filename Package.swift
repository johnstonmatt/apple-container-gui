// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContainerDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ContainerDesk", targets: ["ContainerDesk"])],
    targets: [
        .executableTarget(name: "ContainerDesk", resources: [.process("Resources")]),
        .testTarget(name: "ContainerDeskTests", dependencies: ["ContainerDesk"])
    ]
)
