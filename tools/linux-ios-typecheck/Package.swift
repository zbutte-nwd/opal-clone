// swift-tools-version:5.10
import PackageDescription
let package = Package(
  name: "W8Check",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../../ios/Packages/TetherCore")],
  targets: [
    .target(name: "ManagedSettings"),
    .target(name: "FamilyControls", dependencies: ["ManagedSettings", "Combine"]),
    .target(name: "UIKit"),
    .target(name: "ManagedSettingsUI", dependencies: ["ManagedSettings", "UIKit"]),
    .target(name: "DeviceActivity", dependencies: ["ManagedSettings"]),
    .target(name: "os"),
    .target(name: "Security"),
    .target(name: "Combine"),
    .target(name: "UserNotifications"),
    .target(name: "BackgroundTasks"),
    .target(name: "TetherKitCheck", dependencies: [
      .product(name: "TetherCore", package: "TetherCore"), .product(name: "TetherAPI", package: "TetherCore"),
      "ManagedSettings", "FamilyControls", "DeviceActivity", "os", "Security", "Combine", "UserNotifications"]),
    .target(name: "Extensions", dependencies: [
      .product(name: "TetherCore", package: "TetherCore"), .product(name: "TetherAPI", package: "TetherCore"),
      "TetherKitCheck", "ManagedSettings", "ManagedSettingsUI", "DeviceActivity", "UserNotifications", "UIKit"]),
    .target(name: "AppCore", dependencies: [
      .product(name: "TetherCore", package: "TetherCore"), .product(name: "TetherAPI", package: "TetherCore"),
      "TetherKitCheck", "ManagedSettings", "FamilyControls", "UserNotifications", "UIKit", "BackgroundTasks", "os"]),
    .testTarget(name: "W8Tests", dependencies: ["TetherKitCheck", "AppCore", .product(name: "TetherCore", package: "TetherCore")]),
  ]
)
