@testable import FileActionServiceCore
import FileActionServiceProtocol
import Foundation
import Testing

@Test func moveExecutorMovesAnItemIntoAnEmptyDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("来源", isDirectory: true)
    let destinationDirectory = root.appendingPathComponent("目标", isDirectory: true)
    let source = sourceDirectory.appendingPathComponent("说明.md")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    try Data("内容".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = FileActionServiceMoveExecutor().perform(
        .move(sources: [source], destination: destinationDirectory, conflictPolicy: .prompt)
    )

    let move = try #require(result.get().move)
    #expect(move.conflicts.isEmpty)
    #expect(move.movedItems.map(\.sourceURL) == [source.standardizedFileURL])
    #expect(FileManager.default.fileExists(atPath: destinationDirectory.appendingPathComponent("说明.md").path))
    #expect(!FileManager.default.fileExists(atPath: source.path))
}

@Test func moveExecutorReturnsConflictsWithoutMovingWhenPrompted() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("来源", isDirectory: true)
    let destinationDirectory = root.appendingPathComponent("目标", isDirectory: true)
    let source = sourceDirectory.appendingPathComponent("说明.md")
    let existing = destinationDirectory.appendingPathComponent("说明.md")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    try Data("来源".utf8).write(to: source)
    try Data("既有".utf8).write(to: existing)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = FileActionServiceMoveExecutor().perform(
        .move(sources: [source], destination: destinationDirectory, conflictPolicy: .prompt)
    )

    let move = try #require(result.get().move)
    #expect(move.movedItems.isEmpty)
    #expect(move.conflicts.map(\.sourceURL) == [source.standardizedFileURL])
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: existing, encoding: .utf8) == "既有")
}

@Test func moveExecutorKeepsBothItemsUsingAPredictableName() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("来源", isDirectory: true)
    let destinationDirectory = root.appendingPathComponent("目标", isDirectory: true)
    let source = sourceDirectory.appendingPathComponent("说明.md")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    try Data("来源".utf8).write(to: source)
    try Data("既有".utf8).write(to: destinationDirectory.appendingPathComponent("说明.md"))
    defer { try? FileManager.default.removeItem(at: root) }

    let result = FileActionServiceMoveExecutor().perform(
        .move(sources: [source], destination: destinationDirectory, conflictPolicy: .keepBoth)
    )

    let move = try #require(result.get().move)
    #expect(move.movedItems.map(\.destinationURL.lastPathComponent) == ["说明 2.md"])
    #expect(try String(
        contentsOf: destinationDirectory.appendingPathComponent("说明 2.md"),
        encoding: .utf8
    ) == "来源")
}

@Test func moveExecutorReportsPerItemFailureAndContinuesRemainingBatch() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("来源", isDirectory: true)
    let destinationDirectory = root.appendingPathComponent("目标", isDirectory: true)
    let successfulSource = sourceDirectory.appendingPathComponent("a-可移动.md")
    let failingSource = sourceDirectory.appendingPathComponent("z-失败.md")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    try Data("成功".utf8).write(to: successfulSource)
    try Data("保留来源".utf8).write(to: failingSource)
    defer { try? FileManager.default.removeItem(at: root) }

    let executor = FileActionServiceMoveExecutor(
        volumeMatcher: { _, _ in false },
        copiedItemVerifier: { source, _ in
            if source.standardizedFileURL == failingSource.standardizedFileURL {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    )

    let result = executor.perform(
        .move(
            sources: [failingSource, successfulSource],
            destination: destinationDirectory,
            conflictPolicy: .prompt
        )
    )

    let move = try #require(result.get().move)
    #expect(move.movedItems.map(\.sourceURL) == [successfulSource.standardizedFileURL])
    #expect(move.failedItems.map(\.sourceURL) == [failingSource.standardizedFileURL])
    #expect(FileManager.default.fileExists(atPath: failingSource.path))
    #expect(FileManager.default.fileExists(
        atPath: destinationDirectory.appendingPathComponent(successfulSource.lastPathComponent).path
    ))
}

@Test func moveExecutorRejectsMovingAFolderIntoItsOwnChild() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("来源", isDirectory: true)
    let child = source.appendingPathComponent("子目录", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = FileActionServiceMoveExecutor().perform(
        .move(sources: [source], destination: child, conflictPolicy: .prompt)
    )

    guard case let .failure(failure) = result else {
        Issue.record("移动到自身子目录应被拒绝")
        return
    }
    guard case .malformedRequest = failure else {
        Issue.record("应返回可诊断的请求错误")
        return
    }
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func crossVolumeMovePublishesOnlyAfterVerification() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("来源", isDirectory: true)
    let destinationDirectory = root.appendingPathComponent("目标", isDirectory: true)
    let source = sourceDirectory.appendingPathComponent("资料", isDirectory: true)
    let nested = source.appendingPathComponent("子目录/说明.md")
    try FileManager.default.createDirectory(
        at: nested.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    try Data("跨卷完整性".utf8).write(to: nested)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = FileActionServiceMoveExecutor(volumeMatcher: { _, _ in false }).perform(
        .move(sources: [source], destination: destinationDirectory, conflictPolicy: .prompt)
    )

    let move = try #require(result.get().move)
    let destination = try #require(move.movedItems.first?.destinationURL)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: destination.appendingPathComponent("子目录/说明.md")) == "跨卷完整性")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
    #expect(leftovers == ["资料"])
}

@Test func crossVolumeCancellationAfterTemporaryCopyKeepsSourceAndCleansTemporaryCopy() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("来源", isDirectory: true)
    let destinationDirectory = root.appendingPathComponent("目标", isDirectory: true)
    let source = sourceDirectory.appendingPathComponent("可取消.md")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    try Data("来源必须保留".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }

    let cancellation = CancellationFlag()
    let executor = FileActionServiceMoveExecutor(
        volumeMatcher: { _, _ in false },
        copyItem: { source, temporaryCopy in
            try FileManager.default.copyItem(at: source, to: temporaryCopy)
            cancellation.cancel()
        }
    )
    let result = executor.perform(
        .move(sources: [source], destination: destinationDirectory, conflictPolicy: .prompt),
        isCancelled: { cancellation.isCancelled }
    )

    let move = try #require(result.get().move)
    #expect(move.failedItems.map(\.sourceURL) == [source.standardizedFileURL])
    #expect(move.failedItems.first?.message == "移动已取消，来源项目保持不变。")
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path).isEmpty)
}

@Test func operationStoreReturnsRunningCancellationAndTerminalStateWithoutReexecuting() {
    let store = FileActionServiceOperationStore()
    let requestID = UUID()

    guard case .execute = store.begin(requestID: requestID) else {
        Issue.record("首次请求必须允许执行")
        return
    }
    #expect(store.state(for: requestID).status == .running)
    #expect(store.requestCancellation(for: requestID).status == .cancelling)
    #expect(store.isCancellationRequested(for: requestID))

    store.complete(requestID: requestID, result: .success(.init()))
    #expect(store.state(for: requestID).status == .cancelled)
    guard case let .existing(state) = store.begin(requestID: requestID) else {
        Issue.record("终态请求不得再次执行")
        return
    }
    #expect(state.status == .cancelled)
}

@Test func operationStoreReloadsTerminalResultFromControlledStorage() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storageURL = root.appendingPathComponent("operation-states.json", isDirectory: false)
    let createdURL = root.appendingPathComponent("已创建.md", isDirectory: false)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let requestID = UUID()
    let initialStore = FileActionServiceOperationStore(storageURL: storageURL)
    guard case .execute = initialStore.begin(requestID: requestID) else {
        Issue.record("首次请求必须允许执行")
        return
    }
    initialStore.complete(requestID: requestID, result: .success(.init(createdURL: createdURL)))

    let reloadedStore = FileActionServiceOperationStore(storageURL: storageURL)
    guard case let .existing(state) = reloadedStore.begin(requestID: requestID) else {
        Issue.record("重启后的同一请求必须重放终态")
        return
    }
    #expect(state.status == .completed)
    #expect(state.terminalResult?.createdURL == createdURL.standardizedFileURL)
    #expect(state.failure == nil)
}

@Test func simulatedDiskFullDuringCrossVolumeCopyKeepsSourceAndCleansTemporaryCopy() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("来源", isDirectory: true)
    let destinationDirectory = root.appendingPathComponent("目标", isDirectory: true)
    let source = sourceDirectory.appendingPathComponent("空间不足.md")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    try Data("来源必须保留".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }

    let executor = FileActionServiceMoveExecutor(
        volumeMatcher: { _, _ in false },
        copyItem: { source, temporaryCopy in
            try FileManager.default.copyItem(at: source, to: temporaryCopy)
            throw CocoaError(.fileWriteOutOfSpace)
        }
    )
    let result = executor.perform(
        .move(sources: [source], destination: destinationDirectory, conflictPolicy: .prompt)
    )

    let move = try #require(result.get().move)
    #expect(move.failedItems.map(\.sourceURL) == [source.standardizedFileURL])
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path).isEmpty)
}

@Test func simulatedTargetVolumeDisconnectKeepsSourceAndCleansTemporaryCopy() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("来源", isDirectory: true)
    let destinationDirectory = root.appendingPathComponent("目标", isDirectory: true)
    let source = sourceDirectory.appendingPathComponent("卷断开.md")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    try Data("来源必须保留".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }

    let executor = FileActionServiceMoveExecutor(
        volumeMatcher: { _, _ in false },
        copyItem: { source, temporaryCopy in
            try FileManager.default.copyItem(at: source, to: temporaryCopy)
            throw POSIXError(.ENODEV)
        }
    )
    let result = executor.perform(
        .move(sources: [source], destination: destinationDirectory, conflictPolicy: .prompt)
    )

    let move = try #require(result.get().move)
    #expect(move.failedItems.map(\.sourceURL) == [source.standardizedFileURL])
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path).isEmpty)
}

@Test func crossVolumeVerificationFailurePreservesSourceAndRemovesTemporaryCopy() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("来源", isDirectory: true)
    let destinationDirectory = root.appendingPathComponent("目标", isDirectory: true)
    let source = sourceDirectory.appendingPathComponent("说明.md")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    try Data("必须保留".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }

    let executor = FileActionServiceMoveExecutor(
        volumeMatcher: { _, _ in false },
        copiedItemVerifier: { _, _ in throw CocoaError(.fileReadCorruptFile) }
    )
    let result = executor.perform(
        .move(sources: [source], destination: destinationDirectory, conflictPolicy: .prompt)
    )

    let move = try #require(result.get().move)
    #expect(move.movedItems.isEmpty)
    #expect(move.failedItems.map(\.sourceURL) == [source.standardizedFileURL])
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: source) == "必须保留")
    #expect(try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path).isEmpty)
}

@Test func crossVolumeMovePreservesTopLevelSymbolicLinkWithoutMovingItsTarget() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("来源", isDirectory: true)
    let destinationDirectory = root.appendingPathComponent("目标", isDirectory: true)
    let target = root.appendingPathComponent("真实文件.md")
    let source = sourceDirectory.appendingPathComponent("链接.md")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    try Data("真实内容".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = FileActionServiceMoveExecutor(volumeMatcher: { _, _ in false }).perform(
        .move(sources: [source], destination: destinationDirectory, conflictPolicy: .prompt)
    )

    let move = try #require(result.get().move)
    let destination = try #require(move.movedItems.first?.destinationURL)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: target.path))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == target.path)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "真实内容")
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool { lock.withLock { value } }

    func cancel() {
        lock.withLock { value = true }
    }
}
