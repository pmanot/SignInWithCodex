// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SignInWithCodex",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "SignInWithCodex",
            targets: ["SignInWithCodex"]
        ),
    ],
    targets: [
        .target(
            name: "SignInWithCodex",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "SignInWithCodexTests",
            dependencies: ["SignInWithCodex"]
        ),
    ]
)
