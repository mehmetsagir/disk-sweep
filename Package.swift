// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskSweep",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiskSweep", targets: ["DiskSweep"])
    ],
    targets: [
        // Scanning, safety rules and cleanup logic. No UI, fully testable.
        .target(name: "DiskSweepCore"),
        .executableTarget(name: "DiskSweep", dependencies: ["DiskSweepCore"]),
        .testTarget(name: "DiskSweepCoreTests", dependencies: ["DiskSweepCore"]),
    ]
)
