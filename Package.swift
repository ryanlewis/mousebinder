// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MouseBinder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MouseBinder",
            path: "Sources/MouseBinder",
            // v1 personal build: keep Swift 5 language mode so the C-style CGEventTap
            // callback bridging stays simple (no strict-concurrency ceremony around the
            // main-run-loop callback). Revisit if/when this goes public.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
