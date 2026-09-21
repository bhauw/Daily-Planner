// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SecurityBoundaryProbe",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SecurityBoundaryCore", targets: ["SecurityBoundaryCore"]),
        .executable(name: "SecurityBoundaryProbeApp", targets: ["SecurityBoundaryProbeApp"]),
    ],
    targets: [
        .target(name: "SecurityBoundaryCore"),
        .executableTarget(
            name: "SecurityBoundaryProbeApp",
            dependencies: ["SecurityBoundaryCore"]
        ),
        .testTarget(
            name: "SecurityBoundaryCoreTests",
            dependencies: ["SecurityBoundaryCore"],
            path: "Tests"
        ),
    ]
)
