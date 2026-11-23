// swift-tools-version: 5.9
import PackageDescription

// Fork-owned: exists in no upstream tree, so it is outside the sync-surface gate
// and carries no merge tax. The app target (D9: com.braintimebox.healthcollector)
// links this package once a Mac with a signing identity is available; until then
// the reliability core is exercised by `swift test` in its own workflow.
let package = Package(
    name: "HealthCollectorCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HealthCollectorCore", targets: ["HealthCollectorCore"])
    ],
    targets: [
        .target(name: "HealthCollectorCore"),
        .testTarget(name: "HealthCollectorCoreTests", dependencies: ["HealthCollectorCore"])
    ]
)
