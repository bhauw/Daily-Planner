// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DailyPlanner",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DailyPlannerDomain", targets: ["DailyPlannerDomain"]),
        .library(name: "DailyPlannerPersistence", targets: ["DailyPlannerPersistence"]),
        .library(name: "DailyPlannerGoogle", targets: ["DailyPlannerGoogle"]),
        .library(name: "DailyPlannerApplication", targets: ["DailyPlannerApplication"]),
        .library(name: "DailyPlannerPlatform", targets: ["DailyPlannerPlatform"]),
        .library(name: "DailyPlannerUI", targets: ["DailyPlannerUI"]),
        .library(name: "DailyPlannerAPI", targets: ["DailyPlannerAPI"]),
        .library(name: "DailyPlannerWebHost", targets: ["DailyPlannerWebHost"]),
        .executable(name: "DailyPlannerApp", targets: ["DailyPlannerApp"]),
    ],
    targets: [
        .target(name: "DailyPlannerDomain"),
        .target(name: "DailyPlannerPersistence", dependencies: ["DailyPlannerDomain"]),
        .target(name: "DailyPlannerGoogle", dependencies: ["DailyPlannerDomain"]),
        .target(name: "DailyPlannerApplication", dependencies: ["DailyPlannerDomain"]),
        .target(
            name: "DailyPlannerPlatform",
            dependencies: ["DailyPlannerDomain", "DailyPlannerApplication"]
        ),
        .target(
            name: "DailyPlannerUI",
            dependencies: ["DailyPlannerDomain", "DailyPlannerApplication"]
        ),
        .target(
            name: "DailyPlannerAPI",
            dependencies: [
                "DailyPlannerDomain", "DailyPlannerApplication", "DailyPlannerPlatform",
            ]
        ),
        .target(
            name: "DailyPlannerWebHost",
            dependencies: ["DailyPlannerAPI"]
        ),
        .executableTarget(
            name: "DailyPlannerApp",
            dependencies: [
                "DailyPlannerDomain", "DailyPlannerApplication", "DailyPlannerPersistence",
                "DailyPlannerGoogle", "DailyPlannerPlatform", "DailyPlannerUI",
                "DailyPlannerAPI", "DailyPlannerWebHost",
            ]
        ),
        .testTarget(name: "DailyPlannerDomainTests", dependencies: ["DailyPlannerDomain"]),
        .testTarget(
            name: "DailyPlannerPersistenceTests",
            dependencies: ["DailyPlannerDomain", "DailyPlannerPersistence"]
        ),
        .testTarget(
            name: "DailyPlannerGoogleTests",
            dependencies: ["DailyPlannerDomain", "DailyPlannerPersistence", "DailyPlannerGoogle"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "DailyPlannerApplicationTests",
            dependencies: ["DailyPlannerDomain", "DailyPlannerApplication"]
        ),
        .testTarget(
            name: "DailyPlannerPlatformTests",
            dependencies: ["DailyPlannerDomain", "DailyPlannerApplication", "DailyPlannerPlatform"]
        ),
        .testTarget(
            name: "DailyPlannerUITests",
            dependencies: ["DailyPlannerDomain", "DailyPlannerApplication", "DailyPlannerUI"]
        ),
        .testTarget(
            name: "DailyPlannerAcceptanceTests",
            dependencies: [
                "DailyPlannerDomain", "DailyPlannerApplication", "DailyPlannerPersistence",
                "DailyPlannerPlatform", "DailyPlannerUI",
            ]
        ),
        .testTarget(
            name: "DailyPlannerWebHostTests",
            dependencies: ["DailyPlannerWebHost"]
        ),
        .testTarget(
            name: "DailyPlannerAPITests",
            dependencies: [
                "DailyPlannerDomain", "DailyPlannerApplication", "DailyPlannerPlatform", "DailyPlannerAPI",
            ]
        ),
    ]
)
