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
        .library(name: "SuperRightFeature", targets: ["SuperRightFeature"]),
        .executable(name: "SearchBenchmark", targets: ["SearchBenchmark"])
    ],
    targets: [
        .target(name: "TouchFeatureAPI"),
        .target(
            name: "TouchCore",
            dependencies: ["TouchFeatureAPI"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "FinderFeature", dependencies: ["TouchFeatureAPI"]),
        .target(name: "ScreenshotFeature", dependencies: ["TouchFeatureAPI"]),
        .target(name: "SuperRightFeature", dependencies: ["TouchFeatureAPI"]),
        .executableTarget(name: "SearchBenchmark", dependencies: ["TouchCore"]),
        .testTarget(name: "TouchFeatureAPITests", dependencies: ["TouchFeatureAPI"]),
        .testTarget(name: "TouchCoreTests", dependencies: ["TouchCore", "TouchFeatureAPI"]),
        .testTarget(name: "FeaturePluginTests", dependencies: ["FinderFeature", "ScreenshotFeature", "SuperRightFeature", "TouchFeatureAPI"])
    ]
)
