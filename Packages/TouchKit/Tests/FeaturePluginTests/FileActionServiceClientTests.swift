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
