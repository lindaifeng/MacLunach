import Foundation
import UniformTypeIdentifiers

public enum FileIndexScanner {
    public static func records(root: URL) async throws -> [FileIndexRecord] {
        var result: [FileIndexRecord] = []
        for try await batch in batches(root: root, batchSize: 500) {
            result.append(contentsOf: batch)
        }
        return result
    }

    public static func batches(root: URL, batchSize: Int = 500) -> AsyncThrowingStream<[FileIndexRecord], Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    let keys: Set<URLResourceKey> = [
                        .isDirectoryKey,
                        .contentTypeKey,
                        .fileSizeKey,
                        .creationDateKey,
                        .contentModificationDateKey
                    ]
                    let enumerator = FileManager.default.enumerator(
                        at: root,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsPackageDescendants]
                    )
                    var batch: [FileIndexRecord] = []

                    while let url = enumerator?.nextObject() as? URL {
                        if isExcluded(url, root: root) {
                            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                                enumerator?.skipDescendants()
                            }
                            continue
                        }
                        let values = try url.resourceValues(forKeys: keys)
                        let record = FileIndexRecord(
                            path: url.path,
                            rootPath: root.path,
                            contentType: values.contentType?.identifier ?? "public.data",
                            size: Int64(values.fileSize ?? 0),
                            createdAt: values.creationDate ?? .distantPast,
                            modifiedAt: values.contentModificationDate ?? .distantPast,
                            isDirectory: values.isDirectory ?? false
                        )
                        batch.append(record)
                        if batch.count == max(1, batchSize) {
                            continuation.yield(batch)
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                    if !batch.isEmpty { continuation.yield(batch) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func isExcluded(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = Array(url.standardizedFileURL.pathComponents.dropFirst(rootComponents.count))
        guard !components.isEmpty else { return false }
        if components.contains(".Trash") { return true }
        return zip(components, components.dropFirst()).contains { $0 == "Library" && $1 == "Caches" }
    }
}
