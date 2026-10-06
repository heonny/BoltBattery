// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bolt-battery",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HIDPPKit", targets: ["HIDPPKit"]),
        .executable(name: "batteryctl", targets: ["batteryctl"]),
    ],
    targets: [
        .target(name: "HIDPPKit"),
        .executableTarget(name: "batteryctl", dependencies: ["HIDPPKit"]),
        .testTarget(name: "HIDPPKitTests", dependencies: ["HIDPPKit"]),
    ]
)
