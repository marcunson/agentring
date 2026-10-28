// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentringCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "AgentringCore", targets: ["AgentringCore"])],
    targets: [
        .target(name: "AgentringCore"),
        .testTarget(name: "AgentringCoreTests", dependencies: ["AgentringCore"])
    ]
)
