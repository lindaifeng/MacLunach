import CryptoKit
import Darwin
import FileActionServiceProtocol
import Foundation

/// 文件移动的可测试实现；XPC target 仅负责进程边界与调用方校验。
public struct FileActionServiceMoveExecutor: Sendable {
    public typealias CancellationChecker = @Sendable () -> Bool

    private let volumeMatcher: @Sendable (URL, URL) -> Bool
    private let copiedItemVerifier: @Sendable (URL, URL) throws -> Void
    private let copyItem: @Sendable (URL, URL) throws -> Void

    public init() {
        volumeMatcher = Self.isSameVolume
        copiedItemVerifier = Self.verifyCopiedItem
        copyItem = Self.copyItem
    }

    init(
        volumeMatcher: @escaping @Sendable (URL, URL) -> Bool,
        copiedItemVerifier: @escaping @Sendable (URL, URL) throws -> Void = Self.verifyCopiedItem,
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = Self.copyItem
    ) {
        self.volumeMatcher = volumeMatcher
        self.copiedItemVerifier = copiedItemVerifier
        self.copyItem = copyItem
    }

    public func perform(
        _ action: FileActionServiceAction,
        isCancelled: @escaping CancellationChecker = { false }
    ) -> Result<FileActionServiceActionResult, FileActionServiceFailure> {
        guard action.name == "move" else {
            return .failure(.unsupportedAction(action.name))
        }
        guard let destination = validatedDirectory(action.directory),
              let sourceURLs = action.sourceURLs,
              !sourceURLs.isEmpty,
              let conflictPolicy = action.conflictPolicy else {
            return .failure(.malformedRequest("移动请求缺少来源、目标目录或冲突策略"))
        }

        let sources = Array(Set(sourceURLs.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        for source in sources {
            guard source.isFileURL,
                  FileManager.default.fileExists(atPath: source.path) else {
                return .failure(.malformedRequest("移动来源不存在或不是本地文件"))
            }
            guard canMove(source: source, into: destination) else {
                return .failure(.malformedRequest("不能将文件夹移动到自身或其子目录"))
            }
        }

        let conflicts = sources.compactMap { source -> FileActionServiceMoveConflict? in
            let proposedDestination = destination.appendingPathComponent(source.lastPathComponent)
            guard FileManager.default.fileExists(atPath: proposedDestination.path) else { return nil }
            return .init(sourceURL: source, destinationURL: proposedDestination)
        }
        if !conflicts.isEmpty, conflictPolicy == .prompt || conflictPolicy == .cancel {
            return .success(.init(move: .init(conflicts: conflicts)))
        }

        var movedItems: [FileActionServiceMovedItem] = []
        var skippedSourceURLs: [URL] = []
        var failedItems: [FileActionServiceMoveFailedItem] = []
        for (index, source) in sources.enumerated() {
            if isCancelled() {
                failedItems.append(contentsOf: sources[index...].map(Self.cancelledItem))
                break
            }
            let proposedDestination = destination.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: proposedDestination.path) {
                switch conflictPolicy {
                case .skip:
                    skippedSourceURLs.append(source)
                    continue
                case .keepBoth:
                    break
                case .prompt, .cancel:
                    return .success(.init(move: .init(
                        movedItems: movedItems,
                        skippedSourceURLs: skippedSourceURLs,
                        conflicts: [.init(sourceURL: source, destinationURL: proposedDestination)]
                    )))
                }
            }

            let resolvedDestination: URL
            do {
                resolvedDestination = try destinationURL(
                    for: source,
                    in: destination,
                    keepBoth: conflictPolicy == .keepBoth
                )
                try move(
                    source: source,
                    to: resolvedDestination,
                    isCancelled: isCancelled
                )
                movedItems.append(.init(sourceURL: source, destinationURL: resolvedDestination))
            } catch is MoveCancelledError {
                failedItems.append(Self.cancelledItem(source))
            } catch {
                failedItems.append(.init(
                    sourceURL: source,
                    message: "无法移动该项目，请检查文件权限、可用空间或目标卷状态。"
                ))
            }
        }
        return .success(.init(move: .init(
            movedItems: movedItems,
            skippedSourceURLs: skippedSourceURLs,
            failedItems: failedItems
        )))
    }

    private func validatedDirectory(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url.standardizedFileURL
    }

    private func canMove(source: URL, into destination: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue else { return source != destination }
        return destination != source && !destination.path.hasPrefix(source.path + "/")
    }

    private func destinationURL(for source: URL, in directory: URL, keepBoth: Bool) throws -> URL {
        let proposed = directory.appendingPathComponent(source.lastPathComponent)
        guard keepBoth, FileManager.default.fileExists(atPath: proposed.path) else { return proposed }

        let fileExtension = source.pathExtension
        let baseName = source.deletingPathExtension().lastPathComponent
        for index in 2...10_000 {
            let name = fileExtension.isEmpty
                ? "\(baseName) \(index)"
                : "\(baseName) \(index).\(fileExtension)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private func move(
        source: URL,
        to destination: URL,
        isCancelled: CancellationChecker
    ) throws {
        try Self.throwIfCancelled(isCancelled)
        if volumeMatcher(source, destination.deletingLastPathComponent()) {
            try FileManager.default.moveItem(at: source, to: destination)
            return
        }

        let temporaryDestination = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".touch-move-\(UUID().uuidString).partial",
                isDirectory: false
            )
        var published = false
        defer {
            if !published {
                try? FileManager.default.removeItem(at: temporaryDestination)
            }
        }

        try copyItem(source, temporaryDestination)
        try Self.throwIfCancelled(isCancelled)
        try copiedItemVerifier(source, temporaryDestination)
        try Self.synchronizeCopiedItem(at: temporaryDestination)
        try Self.throwIfCancelled(isCancelled)

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try Self.throwIfCancelled(isCancelled)
        try FileManager.default.moveItem(at: temporaryDestination, to: destination)
        published = true

        // 发布完成后才允许删除来源。若删除失败，保留已验证的目标副本，避免二次数据损失。
        try Self.throwIfCancelled(isCancelled)
        try FileManager.default.removeItem(at: source)
    }

    private struct MoveCancelledError: Error {}

    private static func throwIfCancelled(_ isCancelled: CancellationChecker) throws {
        if isCancelled() {
            throw MoveCancelledError()
        }
    }

    private static func cancelledItem(_ source: URL) -> FileActionServiceMoveFailedItem {
        .init(sourceURL: source, message: "移动已取消，来源项目保持不变。")
    }

    private static func isSameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsID = try? lhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let rhsID = try? rhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return false
        }
        return String(describing: lhsID) == String(describing: rhsID)
    }

    private static func copyItem(_ source: URL, _ destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private enum CopiedItemKind: String, Sendable {
        case directory
        case regularFile
        case symbolicLink
    }

    private struct CopiedItemManifestEntry: Equatable, Sendable {
        let kind: CopiedItemKind
        let size: Int?
        let digest: Data?
        let symbolicLinkDestination: String?
    }

    private struct CopyVerificationError: LocalizedError {
        let detail: String

        var errorDescription: String? {
            "跨卷副本完整性校验失败：\(detail)"
        }
    }

    private static func verifyCopiedItem(_ source: URL, _ copy: URL) throws {
        let sourceManifest = try manifest(at: source)
        let copiedManifest = try manifest(at: copy)
        let sourcePaths = Set(sourceManifest.keys)
        let copiedPaths = Set(copiedManifest.keys)
        guard sourcePaths == copiedPaths else {
            let missing = sourcePaths.subtracting(copiedPaths).sorted()
            let unexpected = copiedPaths.subtracting(sourcePaths).sorted()
            throw CopyVerificationError(detail: "路径不一致，缺失 \(missing)，多出 \(unexpected)")
        }
        for path in sourcePaths.sorted() {
            guard sourceManifest[path] == copiedManifest[path] else {
                throw CopyVerificationError(detail: "项目 \(path) 的类型、大小或内容摘要不一致")
            }
        }
    }

    private static func manifest(at root: URL) throws -> [String: CopiedItemManifestEntry] {
        let originalRoot = root.standardizedFileURL
        let originalRootValues = try originalRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
        if originalRootValues.isSymbolicLink == true {
            return [".": try manifestEntry(at: originalRoot)]
        }

        // macOS 临时目录常通过 /var 指向 /private/var；统一解析根路径，避免枚举器返回的
        // 真实路径与传入路径前缀不同，从而把绝对路径误判为相对路径。
        let resolvedRoot = originalRoot.resolvingSymlinksInPath().standardizedFileURL
        var result: [String: CopiedItemManifestEntry] = [:]
        result["."] = try manifestEntry(at: resolvedRoot)

        let rootValues = try resolvedRoot.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else { return result }
        try appendManifestEntries(
            in: resolvedRoot,
            relativeComponents: [],
            to: &result
        )
        return result
    }

    private static func appendManifestEntries(
        in directory: URL,
        relativeComponents: [String],
        to result: inout [String: CopiedItemManifestEntry]
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ],
            options: []
        )
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let childComponents = relativeComponents + [child.lastPathComponent]
            let relativePath = childComponents.joined(separator: "/")
            let entry = try manifestEntry(at: child)
            result[relativePath] = entry
            if entry.kind == .directory {
                try appendManifestEntries(
                    in: child,
                    relativeComponents: childComponents,
                    to: &result
                )
            }
        }
    }

    private static func manifestEntry(at url: URL) throws -> CopiedItemManifestEntry {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        if values.isSymbolicLink == true {
            return .init(
                kind: .symbolicLink,
                size: nil,
                digest: nil,
                symbolicLinkDestination: try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            )
        }
        if values.isDirectory == true {
            return .init(kind: .directory, size: nil, digest: nil, symbolicLinkDestination: nil)
        }
        if values.isRegularFile == true {
            return .init(
                kind: .regularFile,
                size: values.fileSize,
                digest: try digest(of: url),
                symbolicLinkDestination: nil
            )
        }
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    private static func digest(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }

    private static func synchronizeCopiedItem(at root: URL) throws {
        try synchronizeTree(at: root)
        try synchronizeDirectory(at: root.deletingLastPathComponent())
    }

    private static func synchronizeTree(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        if values.isSymbolicLink == true {
            return
        }
        if values.isRegularFile == true {
            try synchronizeFile(at: url)
            return
        }
        guard values.isDirectory == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        )
        for child in children {
            try synchronizeTree(at: child)
        }
        try synchronizeDirectory(at: url)
    }

    private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
