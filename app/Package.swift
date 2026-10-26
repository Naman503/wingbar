// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wingbar",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (notch geometry, item matching, sections), unit-tested.
        .target(name: "WingbarCore"),
        // The menu-bar app. scripts/bundle.sh wraps the binary into Wingbar.app.
        .executableTarget(name: "Wingbar", dependencies: ["WingbarCore"]),
        .testTarget(name: "WingbarCoreTests", dependencies: ["WingbarCore"]),
    ],
    swiftLanguageModes: [.v5]
)
