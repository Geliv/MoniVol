// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoniVolCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MoniVolCore",
            targets: ["MoniVolCore"]
        )
    ],
    targets: [
        .target(
            name: "MoniVolCore"
        )
    ]
)
