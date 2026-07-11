// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TouchKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TouchFeatureAPI", targets: ["TouchFeatureAPI"]),
        .library(name: "TouchCore", targets: ["TouchCore"]),
        .library(name: "FinderFeature", targets: ["FinderFeature"]),
        .library(name: "ScreenshotFeature", targets: ["ScreenshotFeature"]),
        .library(name: "SuperRightFeature", targets: ["SuperRightFeature"])
    ],
    targets: [
        .target(name: "TouchFeatureAPI"),
        .target(name: "TouchCore", dependencies: ["TouchFeatureAPI"]),
        .target(name: "FinderFeature", dependencies: ["TouchFeatureAPI"]),
        .target(name: "ScreenshotFeature", dependencies: ["TouchFeatureAPI"]),
        .target(name: "SuperRightFeature", dependencies: ["TouchFeatureAPI"]),
        .testTarget(name: "TouchFeatureAPITests", dependencies: ["TouchFeatureAPI"]),
        .testTarget(name: "TouchCoreTests", dependencies: ["TouchCore", "TouchFeatureAPI"]),
        .testTarget(name: "FeaturePluginTests", dependencies: ["FinderFeature", "ScreenshotFeature", "SuperRightFeature", "TouchFeatureAPI"])
    ]
)
