import Foundation

public enum ScreenshotFeaturePathError: Error, Equatable, Sendable {
    case emptyRelativePath
    case absolutePathNotAllowed
    case traversalNotAllowed
    case pathEscapesPluginRoot
}

public struct ScreenshotFeaturePaths: Sendable {
    public static let pluginID = "me.touch.screenshot"

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public static func applicationSupport(fileManager: FileManager = .default) throws -> Self {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return Self(
            rootURL: applicationSupport
                .appendingPathComponent("Touch", isDirectory: true)
                .appendingPathComponent("Features", isDirectory: true)
                .appendingPathComponent(pluginID, isDirectory: true)
        )
    }

    public var capturesURL: URL { rootURL.appendingPathComponent("Captures", isDirectory: true) }
    public var thumbnailsURL: URL { rootURL.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var historyURL: URL { rootURL.appendingPathComponent("History", isDirectory: true) }
    public var trashURL: URL { rootURL.appendingPathComponent(".Trash", isDirectory: true) }
    public var pinsURL: URL { rootURL.appendingPathComponent("Pins", isDirectory: true) }
    public var projectsURL: URL { rootURL.appendingPathComponent("Projects", isDirectory: true) }

    public func resolve(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty else { throw ScreenshotFeaturePathError.emptyRelativePath }
        guard !NSString(string: relativePath).isAbsolutePath else {
            throw ScreenshotFeaturePathError.absolutePathNotAllowed
        }
        let components = NSString(string: relativePath).pathComponents
        guard !components.contains("..") else { throw ScreenshotFeaturePathError.traversalNotAllowed }
        let meaningfulComponents = components.filter { $0 != "." }
        guard !meaningfulComponents.isEmpty else { throw ScreenshotFeaturePathError.emptyRelativePath }

        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        var candidate = resolvedRoot
        for component in meaningfulComponents {
            candidate.appendPathComponent(component)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            let isSymbolicLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil
            if exists || isSymbolicLink {
                candidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            } else {
                candidate = candidate.standardizedFileURL
            }
            guard candidate.path == resolvedRoot.path || candidate.path.hasPrefix(resolvedRoot.path + "/") else {
                throw ScreenshotFeaturePathError.pathEscapesPluginRoot
            }
        }
        return candidate
    }

    public func relativePath(for fileURL: URL) throws -> String {
        let lexicalRoot = rootURL.standardizedFileURL
        let lexicalCandidate = fileURL.standardizedFileURL
        guard lexicalCandidate.path.hasPrefix(lexicalRoot.path + "/") else {
            throw ScreenshotFeaturePathError.pathEscapesPluginRoot
        }

        let lexicalRelativePath = String(lexicalCandidate.path.dropFirst(lexicalRoot.path.count + 1))
        let resolvedCandidate = try resolve(relativePath: lexicalRelativePath)
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw ScreenshotFeaturePathError.pathEscapesPluginRoot
        }
        return String(resolvedCandidate.path.dropFirst(resolvedRoot.path.count + 1))
    }
}
