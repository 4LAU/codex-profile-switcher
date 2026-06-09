// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexProfileSwitcher",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CodexProfileCore",
            targets: ["CodexProfileCore"]),
        .executable(
            name: "CodexProfileSwitcher",
            targets: ["CodexProfileSwitcherApp"]),
        .executable(
            name: "codex-profile",
            targets: ["CodexProfileCLI"]),
    ],
    targets: [
        .target(
            name: "CodexProfileCore",
            path: "Sources/CodexProfileCore"),
        .executableTarget(
            name: "CodexProfileSwitcherApp",
            dependencies: ["CodexProfileCore"],
            path: "Sources/CodexProfileSwitcherApp",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
            ]),
        .executableTarget(
            name: "CodexProfileCLI",
            dependencies: ["CodexProfileCore"],
            path: "Sources/CodexProfileCLI",
            linkerSettings: [
                .linkedFramework("Security"),
            ]),
        .testTarget(
            name: "AuthBlobTests",
            dependencies: ["CodexProfileCore"],
            path: "Tests/AuthBlobTests"),
        .testTarget(
            name: "ProfileSelectorTests",
            dependencies: ["CodexProfileCore"],
            path: "Tests/ProfileSelectorTests"),
        .testTarget(
            name: "LogRedactorTests",
            dependencies: ["CodexProfileSwitcherApp", "CodexProfileCore"],
            path: "Tests/LogRedactorTests",
            swiftSettings: [
                .define("TESTING"),
            ]),
        .testTarget(
            name: "ProfileStoreEnvironmentTests",
            dependencies: ["CodexProfileSwitcherApp", "CodexProfileCore"],
            path: "Tests/ProfileStoreEnvironmentTests",
            swiftSettings: [
                .define("TESTING"),
            ]),
    ]
)
