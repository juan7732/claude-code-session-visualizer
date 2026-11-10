// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SessionVisualizer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkitKit", targets: ["SkitKit"]),
        .executable(name: "SessionVisualizer", targets: ["SessionVisualizer"]),
    ],
    targets: [
        // Everything that talks to `skit`: the transport, the typed /v0 client,
        // the models. No UI, so it is tested without a window.
        .target(name: "SkitKit"),
        // A Unix-socket server that plays `skit serve` in tests.
        .target(name: "SkitTestSupport"),
        .executableTarget(
            name: "SessionVisualizer",
            dependencies: ["SkitKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "SkitKitTests",
            dependencies: ["SkitKit", "SkitTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        // The app's state without its windows: what a click does to the store.
        .testTarget(
            name: "SessionVisualizerTests",
            dependencies: ["SessionVisualizer", "SkitKit", "SkitTestSupport"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
