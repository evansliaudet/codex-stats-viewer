// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexUsageBar",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "CodexUsageBar", targets: ["CodexUsageBar"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexUsageBar",
            path: "Sources/CodexUsageBar"
        ),
    ]
)
