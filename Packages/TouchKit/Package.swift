// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TouchKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TouchFeatureAPI", targets: ["TouchFeatureAPI"]),
        .library(name: "TouchCore", targets: ["TouchCore"])
    ],
    targets: [
        .target(name: "TouchFeatureAPI"),
        .target(name: "TouchCore", dependencies: ["TouchFeatureAPI"]),
        .testTarget(name: "TouchFeatureAPITests", dependencies: ["TouchFeatureAPI"]),
        .testTarget(name: "TouchCoreTests", dependencies: ["TouchCore", "TouchFeatureAPI"])
    ]
)
