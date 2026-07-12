import AppKit
import TouchCore

struct WorkspaceApplicationDiscoverer: ApplicationDiscovering {
    private let fileSystemDiscoverer: FileSystemApplicationDiscoverer

    init(fileSystemDiscoverer: FileSystemApplicationDiscoverer = .init()) {
        self.fileSystemDiscoverer = fileSystemDiscoverer
    }

    func discoverApplications() async -> [ApplicationRecord] {
        let fileSystemApplications = await fileSystemDiscoverer.discoverApplications()
        let knownURLs = await MainActor.run {
            let workspace = NSWorkspace.shared
            let resolvedURLs = fileSystemApplications.compactMap {
                workspace.urlForApplication(withBundleIdentifier: $0.bundleIdentifier)
            }
            let runningURLs = workspace.runningApplications.compactMap(\.bundleURL)
            return Array(Set(resolvedURLs + runningURLs))
        }
        let knownRoots = knownURLs.map {
            ApplicationSearchRoot(url: $0, isUserInstalled: Self.isUserInstalled($0))
        }
        let knownApplications = await FileSystemApplicationDiscoverer(roots: knownRoots).discoverApplications()
        return fileSystemApplications + knownApplications
    }

    private static func isUserInstalled(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .resolvingSymlinksInPath().path
        return path == "/Applications" || path.hasPrefix("/Applications/")
            || path == homeApplications || path.hasPrefix(homeApplications + "/")
    }
}

struct WorkspaceApplicationLauncher: ApplicationLaunching {
    private enum LaunchError: Error {
        case noRunningApplication
    }

    func openApplication(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if application == nil {
                        continuation.resume(throwing: LaunchError.noRunningApplication)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
}
