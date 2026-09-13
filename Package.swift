// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SnapcastSource",
    platforms: [.macOS(.v14)],
    targets: [
        // No dependencies on purpose. Everything here is AudioToolbox/CoreAudio from the
        // system SDK, so the binary is self-contained and `swift build` works offline.
        .executableTarget(
            name: "snapcap",
            path: "Sources/snapcap"
        )
    ]
)
