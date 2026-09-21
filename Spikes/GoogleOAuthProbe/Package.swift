// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GoogleOAuthProbe",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GoogleOAuthCore", targets: ["GoogleOAuthCore"]),
        .executable(name: "google-oauth-probe", targets: ["google-oauth-probe"]),
    ],
    targets: [
        .target(name: "GoogleOAuthCore"),
        .executableTarget(
            name: "google-oauth-probe",
            dependencies: ["GoogleOAuthCore"]
        ),
        .testTarget(
            name: "GoogleOAuthCoreTests",
            dependencies: ["GoogleOAuthCore"]
        ),
    ]
)
