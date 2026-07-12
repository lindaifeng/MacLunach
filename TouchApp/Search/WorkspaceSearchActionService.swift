import AppKit
import Foundation
import QuickLookUI

@MainActor
protocol SearchActionServicing: AnyObject {
    func openFile(at url: URL) throws
    func revealFile(at url: URL) throws
    func previewFile(at url: URL) throws
}

enum SearchFixtureActionLog {
    private static let lock = NSLock()

    static func append(_ action: String, url: URL, to logURL: URL?) {
        guard let logURL, let data = "\(action)|\(url.path)\n".data(using: .utf8) else { return }
        lock.withLock {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}

enum SearchFixtureActionError: Error {
    case requestedFailure
}

@MainActor
final class WorkspaceSearchActionService: NSObject, SearchActionServicing, @preconcurrency QLPreviewPanelDataSource {
    private enum ActionError: Error {
        case unavailable
    }

    private var previewURL: URL?

    func openFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path), NSWorkspace.shared.open(url) else {
            throw ActionError.unavailable
        }
    }

    func revealFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              NSWorkspace.shared.selectFile(
                url.path,
                inFileViewerRootedAtPath: url.deletingLastPathComponent().path
              ) else {
            throw ActionError.unavailable
        }
    }

    func previewFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path), let panel = QLPreviewPanel.shared() else {
            throw ActionError.unavailable
        }
        previewURL = url
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        previewURL! as NSURL
    }
}

@MainActor
final class FixtureSearchActionService: SearchActionServicing {
    private let logURL: URL?
    private let failingAction: String?

    init(logURL: URL?, failingAction: String? = nil) {
        self.logURL = logURL
        self.failingAction = failingAction
    }

    func openFile(at url: URL) throws {
        try failIfRequested("open")
        SearchFixtureActionLog.append("open", url: url, to: logURL)
    }

    func revealFile(at url: URL) throws {
        try failIfRequested("reveal")
        SearchFixtureActionLog.append("reveal", url: url, to: logURL)
    }

    func previewFile(at url: URL) throws {
        try failIfRequested("preview")
        SearchFixtureActionLog.append("preview", url: url, to: logURL)
    }

    private func failIfRequested(_ action: String) throws {
        if failingAction == action { throw SearchFixtureActionError.requestedFailure }
    }
}
