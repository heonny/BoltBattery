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
        .target(name: "Diagnostics"),
        .target(name: "HIDPPKit", dependencies: ["Diagnostics"]),
        .target(name: "BatteryHistory", dependencies: ["Diagnostics"]),
        .executableTarget(name: "batteryctl", dependencies: ["HIDPPKit"]),
        .executableTarget(name: "BoltBattery", dependencies: ["HIDPPKit", "BatteryHistory", "Diagnostics"]),
        .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics"]),
        .testTarget(name: "BoltBatteryTests", dependencies: ["BoltBattery"]),
        .testTarget(name: "HIDPPKitTests", dependencies: ["HIDPPKit"]),
        .testTarget(name: "BatteryHistoryTests", dependencies: ["BatteryHistory"]),
    ]
)
