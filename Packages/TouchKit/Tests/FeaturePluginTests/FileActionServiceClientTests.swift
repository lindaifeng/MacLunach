import Foundation
import Testing
import FileActionServiceProtocol
@testable import SuperRightFeature

@Test func fileActionClientPingReturnsDecodedServiceIdentity() async throws {
    let processor = FileActionServiceRequestProcessor(
        processID: 73,
        now: { Date(timeIntervalSince1970: 1_750_000_001) }
    )
    let connection = MockFileActionServiceConnection { data, reply, _ in
        reply(processor.process(data))
    }
    let client = FileActionServiceClient(connectionFactory: { connection })

    let pong = try await client.ping(timeout: .seconds(1))

    #expect(pong.processID == 73)
    #expect(pong.timestamp == Date(timeIntervalSince1970: 1_750_000_001))
    #expect(connection.resumeCount == 1)
    #expect(connection.invalidateCount == 0)
}

@Test func fileActionClientQueriesAndCancelsOperationUsingTheReferencedRequestID() async throws {
    let operationID = UUID()
    let processor = FileActionServiceRequestProcessor(actionHandler: { action in
        guard action.operationRequestID == operationID else {
            return .failure(.malformedRequest("缺少目标请求 ID"))
        }
        let status: FileActionServiceOperationStatus = action.name == "cancelOperation"
            ? .cancelling
            : .running
        return .success(.init(operationState: .init(requestID: operationID, status: status)))
    })
    let connection = MockFileActionServiceConnection { data, reply, _ in
        reply(processor.process(data))
    }
    let client = FileActionServiceClient(connectionFactory: { connection })

    let current = try await client.operationState(for: operationID)
    let cancellation = try await client.cancelOperation(requestID: operationID)

    #expect(current == .init(requestID: operationID, status: .running))
    #expect(cancellation == .init(requestID: operationID, status: .cancelling))
}

@Test func fileActionClientTimeoutReturnsDeterministicallyAndInvalidatesConnection() async {
    let connection = MockFileActionServiceConnection { _, _, _ in }
    let client = FileActionServiceClient(connectionFactory: { connection })

    do {
        _ = try await client.ping(timeout: .milliseconds(20))
        Issue.record("无响应的服务不应让 ping 成功")
    } catch let error as FileActionServiceClientError {
        #expect(error == .timedOut)
    } catch {
        Issue.record("收到非预期错误类型：\(error)")
    }

    #expect(connection.invalidateCount == 1)
}

@Test func fileActionClientInterruptionFinishesPendingPingWithoutWaitingForTimeout() async {
    let connection = MockFileActionServiceConnection { _, _, _ in }
    let client = FileActionServiceClient(connectionFactory: { connection })
    let ping = Task {
        try await client.ping(timeout: .seconds(5))
    }

    for _ in 0..<1_000 where connection.performCount == 0 {
        await Task.yield()
    }
    connection.triggerInterruption()

    do {
        _ = try await ping.value
        Issue.record("中断的连接不应让 ping 成功")
    } catch let error as FileActionServiceClientError {
        #expect(error == .interrupted)
    } catch {
        Issue.record("收到非预期错误类型：\(error)")
    }

    #expect(connection.invalidateCount == 1)
}

@Test func relayRequestExpiresBeforeItCanBeConsumed() {
    let createdAt = Date(timeIntervalSince1970: 1_750_000_000)
    let request = FileActionServiceRelayRequest(
        action: .createFolder(directory: URL(fileURLWithPath: "/tmp")),
        createdAt: createdAt,
        expiresAt: createdAt.addingTimeInterval(12)
    )

    #expect(!request.isExpired(at: createdAt.addingTimeInterval(11.9)))
    #expect(request.isExpired(at: createdAt.addingTimeInterval(12)))
}

@Test func relayResultCacheReplaysOnlyTheOriginalActionForTheSameRequestID() {
    let id = UUID()
    let original = FileActionServiceRelayRequest(
        id: id,
        action: .createFolder(directory: URL(fileURLWithPath: "/tmp/original"))
    )
    let response = FileActionServiceResponse(
        requestID: id,
        payload: .actionResult(.init(createdURL: URL(fileURLWithPath: "/tmp/original/未命名文件夹")))
    )
    var cache = FileActionServiceRelayResultCache()
    cache.store(response, for: original, at: Date(timeIntervalSince1970: 1_750_000_000))

    let retry = FileActionServiceRelayRequest(
        id: id,
        responseChallenge: UUID(),
        action: original.action
    )
    #expect(cache.response(for: retry) == response)

    let altered = FileActionServiceRelayRequest(
        id: id,
        action: .createFolder(directory: URL(fileURLWithPath: "/tmp/altered"))
    )
    #expect(cache.response(for: altered) == nil)
    #expect(cache.containsRequestID(id))
}

@Test func relayAcceptsOnlyRegularOwnerControlledRequestWithMatchingFilename() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let request = FileActionServiceRelayRequest(
        action: .createFolder(directory: URL(fileURLWithPath: "/tmp"))
    )
    let url = directory.appendingPathComponent("\(request.id.uuidString).json")
    try JSONEncoder().encode(request).write(to: url, options: .atomic)

    let pending = FileActionServiceRelay.pendingRequests(in: directory)

    #expect(pending.map(\.request) == [request])
}

@Test func relayQuarantinesRequestWhenFilenameDoesNotMatchPayloadID() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let request = FileActionServiceRelayRequest(
        action: .createFolder(directory: URL(fileURLWithPath: "/tmp"))
    )
    let url = directory.appendingPathComponent("\(UUID().uuidString).json")
    try JSONEncoder().encode(request).write(to: url, options: .atomic)

    #expect(FileActionServiceRelay.pendingRequests(in: directory).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func relayRejectsSymbolicLinkRequestFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let request = FileActionServiceRelayRequest(
        action: .createFolder(directory: URL(fileURLWithPath: "/tmp"))
    )
    let backingURL = directory.appendingPathComponent("backing")
    try JSONEncoder().encode(request).write(to: backingURL, options: .atomic)
    let linkURL = directory.appendingPathComponent("\(request.id.uuidString).json")
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: backingURL)

    #expect(FileActionServiceRelay.pendingRequests(in: directory).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: linkURL.path))
    #expect(FileManager.default.fileExists(atPath: backingURL.path))
}

private final class MockFileActionServiceConnection: FileActionServiceConnection, @unchecked Sendable {
    typealias Handler = @Sendable (
        Data,
        @escaping @Sendable (Data) -> Void,
        @escaping @Sendable (any Error) -> Void
    ) -> Void

    private let lock = NSLock()
    private let handler: Handler
    private var storedInterruptionHandler: (@Sendable () -> Void)?
    private var storedInvalidationHandler: (@Sendable () -> Void)?
    private var storedResumeCount = 0
    private var storedPerformCount = 0
    private var storedInvalidateCount = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var interruptionHandler: (@Sendable () -> Void)? {
        get { lock.withLock { storedInterruptionHandler } }
        set { lock.withLock { storedInterruptionHandler = newValue } }
    }

    var invalidationHandler: (@Sendable () -> Void)? {
        get { lock.withLock { storedInvalidationHandler } }
        set { lock.withLock { storedInvalidationHandler = newValue } }
    }

    var resumeCount: Int { lock.withLock { storedResumeCount } }
    var performCount: Int { lock.withLock { storedPerformCount } }
    var invalidateCount: Int { lock.withLock { storedInvalidateCount } }

    func resume() {
        lock.withLock { storedResumeCount += 1 }
    }

    func perform(
        requestData: Data,
        reply: @escaping @Sendable (Data) -> Void,
        failure: @escaping @Sendable (any Error) -> Void
    ) {
        lock.withLock { storedPerformCount += 1 }
        handler(requestData, reply, failure)
    }

    func invalidate() {
        lock.withLock { storedInvalidateCount += 1 }
    }

    func triggerInterruption() {
        interruptionHandler?()
    }
}
