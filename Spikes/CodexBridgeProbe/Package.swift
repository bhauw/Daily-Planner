// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexBridgeProbe",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodexBridgeCore", targets: ["CodexBridgeCore"]),
        .executable(name: "codex-bridge-probe", targets: ["codex-bridge-probe"]),
    ],
    targets: [
        .target(name: "CodexBridgeCore"),
        .executableTarget(
            name: "codex-bridge-probe",
            dependencies: ["CodexBridgeCore"]
        ),
        .testTarget(
            name: "CodexBridgeCoreTests",
            dependencies: ["CodexBridgeCore"]
        ),
    ]
)
