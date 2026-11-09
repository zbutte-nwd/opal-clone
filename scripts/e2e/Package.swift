// swift-tools-version:5.10
import PackageDescription
let package = Package(name: "E2E", platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../../ios/Packages/TetherCore")],
  targets: [.executableTarget(name: "E2E", dependencies: [.product(name: "TetherCore", package: "TetherCore")])])
