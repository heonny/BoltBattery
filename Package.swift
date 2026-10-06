// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bolt-battery",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HIDPPKit", targets: ["HIDPPKit"]),
        .executable(name: "batteryctl", targets: ["batteryctl"]),
        .executable(name: "BoltBattery", targets: ["BoltBattery"]),
    ],
    targets: [
        .target(name: "HIDPPKit"),
        .executableTarget(name: "batteryctl", dependencies: ["HIDPPKit"]),
        .executableTarget(name: "BoltBattery", dependencies: ["HIDPPKit"]),
        .testTarget(name: "HIDPPKitTests", dependencies: ["HIDPPKit"]),
    ]
)
