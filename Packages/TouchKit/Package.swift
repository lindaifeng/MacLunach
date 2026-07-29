// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TouchKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TouchFeatureAPI", targets: ["TouchFeatureAPI"]),
        .library(name: "TouchCore", targets: ["TouchCore"]),
        .library(name: "FinderFeature", targets: ["FinderFeature"]),
        .library(name: "ScreenshotFeature", type: .static, targets: ["ScreenshotFeature"]),
        .library(name: "ScreenshotServiceProtocol", targets: ["ScreenshotServiceProtocol"]),
        .library(name: "ScreenshotServiceCore", targets: ["ScreenshotServiceCore"]),
        .library(name: "SuperRightFeature", targets: ["SuperRightFeature"]),
        .library(name: "DailyTaskFeature", targets: ["DailyTaskFeature"]),
        .library(name: "PomodoroFeature", targets: ["PomodoroFeature"]),
        .library(name: "HolidayCalendarFeature", targets: ["HolidayCalendarFeature"]),
        .library(name: "MarkdownPreviewFeature", targets: ["MarkdownPreviewFeature"]),
        .library(name: "ParserToolsFeature", targets: ["ParserToolsFeature"]),
        .library(name: "ClipboardFeature", targets: ["ClipboardFeature"]),
        .library(name: "TranslationFeature", targets: ["TranslationFeature"]),
        .library(name: "OCRFeature", targets: ["OCRFeature"]),
        .library(name: "FileActionServiceProtocol", targets: ["FileActionServiceProtocol"]),
        .library(name: "FileActionServiceCore", targets: ["FileActionServiceCore"]),
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
        .target(name: "ScreenshotServiceProtocol"),
        .target(
            name: "ScreenshotFeature",
            dependencies: ["TouchFeatureAPI", "ScreenshotServiceProtocol"]
        ),
        .target(
            name: "ScreenshotServiceCore",
            dependencies: ["ScreenshotFeature"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "FileActionServiceProtocol"),
        .target(
            name: "FileActionServiceCore",
            dependencies: ["FileActionServiceProtocol"]
        ),
        .target(
            name: "SuperRightFeature",
            dependencies: ["TouchFeatureAPI", "FileActionServiceProtocol"]
        ),
        .target(
            name: "DailyTaskFeature",
            dependencies: ["TouchFeatureAPI"],
            linkerSettings: [.linkedFramework("EventKit")]
        ),
        .target(name: "PomodoroFeature", dependencies: ["TouchFeatureAPI"]),
        .target(name: "HolidayCalendarFeature", dependencies: ["TouchFeatureAPI"]),
        .target(name: "MarkdownPreviewFeature", dependencies: ["TouchFeatureAPI"]),
        .target(name: "ParserToolsFeature", dependencies: ["TouchFeatureAPI"]),
        .target(name: "ClipboardFeature", dependencies: ["TouchFeatureAPI"], linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Security")]),
        .target(name: "TranslationFeature", dependencies: ["TouchFeatureAPI"]),
        .target(name: "OCRFeature", dependencies: ["TouchFeatureAPI"]),
        .executableTarget(name: "SearchBenchmark", dependencies: ["TouchCore"]),
        .testTarget(name: "TouchFeatureAPITests", dependencies: ["TouchFeatureAPI"]),
        .testTarget(name: "TouchCoreTests", dependencies: ["TouchCore", "TouchFeatureAPI"]),
        .testTarget(name: "ClipboardFeatureTests", dependencies: ["ClipboardFeature"]),
        .testTarget(name: "TranslationFeatureTests", dependencies: ["TranslationFeature", "TouchFeatureAPI"]),
        .testTarget(name: "OCRFeatureTests", dependencies: ["OCRFeature", "TouchFeatureAPI"]),
        .testTarget(name: "MarkdownPreviewFeatureTests", dependencies: ["MarkdownPreviewFeature"]),
        .testTarget(
            name: "ScreenshotFeatureTests",
            dependencies: ["ScreenshotFeature", "ScreenshotServiceProtocol", "TouchFeatureAPI"]
        ),
        .testTarget(
            name: "ScreenshotServiceCoreTests",
            dependencies: ["ScreenshotServiceCore", "ScreenshotFeature"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "FeaturePluginTests",
            dependencies: [
                "FileActionServiceProtocol",
                "FinderFeature",
                "ScreenshotFeature",
                "SuperRightFeature",
                "DailyTaskFeature",
                "PomodoroFeature",
                "HolidayCalendarFeature",
                "MarkdownPreviewFeature",
                "ParserToolsFeature",
                "ClipboardFeature",
                "TranslationFeature",
                "OCRFeature",
                "TouchFeatureAPI"
            ]
        ),
        .testTarget(
            name: "FileActionServiceCoreTests",
            dependencies: ["FileActionServiceCore", "FileActionServiceProtocol"]
        )
    ]
)
