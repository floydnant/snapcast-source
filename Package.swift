// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SnapcastSource",
    // 14.2 is the floor for CoreAudio process taps, which is what lets the app capture
    // system audio without shipping a virtual audio driver.
    platforms: [.macOS("14.2")],
    targets: [
        // No third-party dependencies on purpose. Everything is system frameworks, so
        // `swift build` works offline and nothing needs auditing.

        // Pipeline shared by the menu bar app and the CLI: tap, convert, discover, stream.
        .target(
            name: "StreamCore",
            path: "Sources/StreamCore"
        ),
        // Menu bar app. `make app` wraps it into a signed .app bundle.
        .executableTarget(
            name: "SnapcastSource",
            dependencies: ["StreamCore"],
            path: "Sources/SnapcastSource"
        ),
        // Headless front end to the same pipeline, for testing and debugging.
        .executableTarget(
            name: "snapstream",
            dependencies: ["StreamCore"],
            path: "Sources/snapstream"
        ),
        // The original BlackHole capture tool. Still works against the relay's raw mode.
        .executableTarget(
            name: "snapcap",
            path: "Sources/snapcap"
        ),
        .testTarget(
            name: "StreamCoreTests",
            dependencies: ["StreamCore"],
            path: "Tests/StreamCoreTests"
        ),
    ]
)
