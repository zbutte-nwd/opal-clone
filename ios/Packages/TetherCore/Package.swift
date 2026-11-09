// swift-tools-version:5.10
// TetherCore — shared code for the Tether app and all of its extensions.
//
//  TetherCore : pure Swift + Foundation. Models, PolicyEngine, TransitionPlanner, StateStore.
//               Builds & tests on Linux (CI) and Apple platforms.
//  TetherAPI  : Foundation-only networking (APIClient, SyncEngine, PushPayload). Linux-testable.
//  TetherKit  : Apple-only glue (FamilyControls / ManagedSettings / DeviceActivity).
//               Every file is wrapped in `#if canImport(ManagedSettings)` so the package
//               still builds on Linux (the module is just empty there).
import PackageDescription

let package = Package(
    name: "TetherCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TetherCore", targets: ["TetherCore"]),
        .library(name: "TetherAPI", targets: ["TetherAPI"]),
        .library(name: "TetherKit", targets: ["TetherKit"]),
    ],
    targets: [
        .target(name: "TetherCore"),
        .target(name: "TetherAPI", dependencies: ["TetherCore"]),
        .target(name: "TetherKit", dependencies: ["TetherCore", "TetherAPI"]),
        .testTarget(name: "TetherCoreTests", dependencies: ["TetherCore"]),
        .testTarget(name: "TetherAPITests", dependencies: ["TetherAPI", "TetherCore"]),
    ]
)
