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

    public static func batches(
        root: URL,
        indexRoot: URL? = nil,
        includeRoot: Bool = false,
        exclusionRules: [String]? = nil,
        batchSize: Int = 500
    ) -> AsyncThrowingStream<[FileIndexRecord], Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
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
                let recordRoot = (indexRoot ?? root).standardizedFileURL
                let effectiveExclusionRules = exclusionRules ?? ["废纸篓", "Library/Caches"]

                if includeRoot,
                   let record = makeRecord(for: root.standardizedFileURL, root: recordRoot, keys: keys) {
                    batch.append(record)
                }

                while let url = enumerator?.nextObject() as? URL {
                    if isExcluded(url, root: root, rules: effectiveExclusionRules) {
                        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                            enumerator?.skipDescendants()
                        }
                        continue
                    }
                    // One unreadable or concurrently removed item must not abort an
                    // otherwise healthy root scan.
                    guard let record = makeRecord(for: url, root: recordRoot, keys: keys) else { continue }
                    batch.append(record)
                    if batch.count == max(1, batchSize) {
                        continuation.yield(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                if !batch.isEmpty { continuation.yield(batch) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func makeRecord(
        for url: URL,
        root: URL,
        keys: Set<URLResourceKey>
    ) -> FileIndexRecord? {
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return FileIndexRecord(
            path: url.path,
            rootPath: root.path,
            contentType: values.contentType?.identifier ?? "public.data",
            size: Int64(values.fileSize ?? 0),
            createdAt: values.creationDate ?? .distantPast,
            modifiedAt: values.contentModificationDate ?? .distantPast,
            isDirectory: values.isDirectory ?? false
        )
    }

    public static func isExcluded(_ url: URL, root: URL, rules: [String]) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = Array(url.standardizedFileURL.pathComponents.dropFirst(rootComponents.count))
        guard !components.isEmpty else { return false }

        return rules.contains { rawRule in
            let rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.isEmpty else { return false }

            if rule == "废纸篓" {
                return components.contains(".Trash") || components.contains("废纸篓")
            }
            if rule == "系统目录" {
                return components.first == "System"
            }
            if rule.hasPrefix("/") {
                let excludedPath = URL(fileURLWithPath: rule).standardizedFileURL.path
                let candidatePath = url.standardizedFileURL.path
                return candidatePath == excludedPath || candidatePath.hasPrefix(excludedPath + "/")
            }

            let ruleComponents = rule
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !ruleComponents.isEmpty, ruleComponents.count <= components.count else { return false }

            for startIndex in 0...(components.count - ruleComponents.count) {
                if Array(components[startIndex..<(startIndex + ruleComponents.count)]) == ruleComponents {
                    return true
                }
            }
            return false
        }
    }
}
