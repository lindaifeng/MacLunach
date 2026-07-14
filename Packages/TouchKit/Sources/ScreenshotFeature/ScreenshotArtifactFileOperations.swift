import Foundation

public struct ScreenshotArtifactExportRequest: Codable, Equatable, Sendable {
    public var artifact: ScreenshotArtifact
    public var destinationPath: String

    public init(artifact: ScreenshotArtifact, destinationURL: URL) {
        self.artifact = artifact
        destinationPath = destinationURL.path
    }

    public var destinationURL: URL {
        URL(fileURLWithPath: destinationPath)
    }
}

public struct ScreenshotArtifactExportResult: Codable, Equatable, Sendable {
    public var destinationPath: String

    public init(destinationURL: URL) {
        destinationPath = destinationURL.path
    }

    public var destinationURL: URL {
        URL(fileURLWithPath: destinationPath)
    }
}

public struct ScreenshotArtifactDeletionRequest: Codable, Equatable, Sendable {
    public var artifact: ScreenshotArtifact

    public init(artifact: ScreenshotArtifact) {
        self.artifact = artifact
    }
}
