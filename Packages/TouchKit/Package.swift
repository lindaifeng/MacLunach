// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TouchKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TouchFeatureAPI", targets: ["TouchFeatureAPI"])
    ],
    targets: [
        .target(name: "TouchFeatureAPI"),
        .testTarget(name: "TouchFeatureAPITests", dependencies: ["TouchFeatureAPI"])
    ]
)
