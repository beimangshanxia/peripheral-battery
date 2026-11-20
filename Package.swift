// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PeripheralBattery",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PeripheralBattery", targets: ["PeripheralBattery"])],
    targets: [
        .target(name: "BatteryCore"),
        .executableTarget(name: "PeripheralBattery", dependencies: ["BatteryCore"]),
        .testTarget(name: "BatteryCoreTests", dependencies: ["BatteryCore"]),
    ],
    swiftLanguageModes: [.v5]
)
