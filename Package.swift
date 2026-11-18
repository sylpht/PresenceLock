// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PresenceLock",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PresenceLockCore", targets: ["PresenceLockCore"]),
        .executable(name: "PresenceLock", targets: ["PresenceLockApp"]),
        .executable(name: "PresenceLockCoreChecks", targets: ["PresenceLockCoreChecks"])
    ],
    targets: [
        .target(name: "PresenceLockCore"),
        .executableTarget(
            name: "PresenceLockApp",
            dependencies: ["PresenceLockCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(
            name: "PresenceLockCoreChecks",
            dependencies: ["PresenceLockCore"]
        )
    ]
)
