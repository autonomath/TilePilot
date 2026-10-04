// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TilePilot",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "TilePilot", targets: ["TilePilot"]),
    ],
    targets: [
        .executableTarget(
            name: "TilePilot",
            path: "Sources/TilePilot"
        ),
        .testTarget(
            name: "TilePilotTests",
            dependencies: ["TilePilot"],
            path: "Tests/TilePilotTests"
        ),
    ]
)
