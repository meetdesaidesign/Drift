// swift-tools-version: 6.1
import PackageDescription

// This package exists to build and test DriftCore, the pure-Foundation logic layer.
// The Drift.app and Drift.saver bundles are assembled by ./build.sh, which compiles
// DriftCore, DriftShared and the per-bundle sources together with swiftc.
let package = Package(
    name: "Drift",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "DriftCore"),
        .testTarget(name: "DriftCoreTests", dependencies: ["DriftCore"]),
    ]
)
