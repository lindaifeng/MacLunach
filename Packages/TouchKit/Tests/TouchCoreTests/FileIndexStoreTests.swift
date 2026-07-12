import Foundation
import Testing
@testable import TouchCore

@Test func storeFindsPartialFileName() async throws {
    let store = try FileIndexStore.temporary()
    try await store.upsert([
        FileIndexRecord(path: "/tmp/项目/设计说明.md", rootPath: "/tmp/项目", contentType: "net.daringfireball.markdown", size: 10, createdAt: .now, modifiedAt: .now, isDirectory: false),
        FileIndexRecord(path: "/tmp/项目/日报.txt", rootPath: "/tmp/项目", contentType: "public.plain-text", size: 8, createdAt: .now, modifiedAt: .now, isDirectory: false)
    ])

    #expect(try await store.search("设计", limit: 10).map(\.fileName) == ["设计说明.md"])
}

@Test func deletingRootRemovesOnlyMatchingRows() async throws {
    let store = try FileIndexStore.temporary()
    try await store.upsert([
        FileIndexRecord(path: "/a/one.txt", rootPath: "/a", contentType: "public.plain-text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false),
        FileIndexRecord(path: "/b/two.txt", rootPath: "/b", contentType: "public.plain-text", size: 1, createdAt: .now, modifiedAt: .now, isDirectory: false)
    ])

    try await store.delete(root: "/a")

    #expect(try await store.search("", limit: 10).map(\.path) == ["/b/two.txt"])
}
