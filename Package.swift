// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ArchBox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ArchBox",
            path: "Sources/ArchBox",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
