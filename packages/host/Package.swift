// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MoniVolHost",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "CMoniVolAudio",
            path: "Sources/CMoniVolAudio",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "MoniVolHost",
            dependencies: ["CMoniVolAudio"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
