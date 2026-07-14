import Foundation
import ScreenshotServiceProtocol
import Testing
@testable import ScreenshotFeature

@Test func serviceProcessorReturnsStructuredFailuresWithMatchingRequestID() throws {
    let processor = ScreenshotServiceRequestProcessor(processID: 4242)
    let incompatible = ScreenshotServiceRequest(
        protocolVersion: ScreenshotServiceProtocolVersion.current + 1,
        action: .ping
    )

    let incompatibleResponse = try JSONDecoder().decode(
        ScreenshotServiceResponse.self,
        from: processor.process(try JSONEncoder().encode(incompatible))
    )
    #expect(incompatibleResponse.requestID == incompatible.id)
    #expect(incompatibleResponse.payload == .failure(.incompatibleProtocol(
        expected: ScreenshotServiceProtocolVersion.current,
        received: ScreenshotServiceProtocolVersion.current + 1
    )))

    let unsupported = ScreenshotServiceRequest(action: .custom(name: "capture", isIdempotent: false))
    let unsupportedResponse = try JSONDecoder().decode(
        ScreenshotServiceResponse.self,
        from: processor.process(try JSONEncoder().encode(unsupported))
    )
    #expect(unsupportedResponse.requestID == unsupported.id)
    #expect(unsupportedResponse.payload == .failure(.unsupportedAction("capture")))
}

@Test func screenshotClientIgnoresDuplicateReplies() async throws {
    let connection = MockScreenshotServiceConnection { _, data, reply, _ in
        let response = try! makeResponse(for: data, payload: .pong(.init(processID: 11)))
        reply(response)
        reply(response)
    }
    let factory = MockScreenshotConnectionFactory([connection])
    let client = ScreenshotClient(connectionFactory: { factory.makeConnection() })

    let pong = try await client.ping(timeout: .seconds(1))

    #expect(pong.processID == 11)
    #expect(connection.performCount == 1)
}

@Test func screenshotClientRejectsMismatchedResponseID() async {
    let connection = MockScreenshotServiceConnection { _, _, reply, _ in
        let response = ScreenshotServiceResponse(
            requestID: UUID(),
            payload: .pong(.init(processID: 12))
        )
        reply(try! JSONEncoder().encode(response))
    }
    let client = ScreenshotClient(connectionFactory: { connection })

    do {
        _ = try await client.ping(timeout: .seconds(1))
        Issue.record("响应 ID 不一致时不应成功")
    } catch let error as ScreenshotFeatureError {
        guard case .responseMismatch = error else {
            Issue.record("收到非预期错误：\(error)")
            return
        }
    } catch {
        Issue.record("收到非预期错误类型：\(error)")
    }
}

@Test func screenshotClientTimeoutCancelsRequestAndInvalidatesConnection() async {
    let connection = MockScreenshotServiceConnection { _, _, _, _ in }
    let client = ScreenshotClient(connectionFactory: { connection })

    do {
        _ = try await client.ping(timeout: .milliseconds(20))
        Issue.record("超时请求不应成功")
    } catch let error as ScreenshotFeatureError {
        #expect(error == .serviceTimedOut)
    } catch {
        Issue.record("收到非预期错误类型：\(error)")
    }

    #expect(connection.cancelledRequestIDs.count == 1)
    #expect(connection.invalidateCount == 1)
}

@Test func screenshotClientRetriesOneInterruptedIdempotentRequestOnly() async throws {
    let first = MockScreenshotServiceConnection { connection, _, _, _ in
        connection.interrupt()
    }
    let second = MockScreenshotServiceConnection { _, data, reply, _ in
        reply(try! makeResponse(for: data, payload: .pong(.init(processID: 22))))
    }
    let retryFactory = MockScreenshotConnectionFactory([first, second])
    let retryingClient = ScreenshotClient(connectionFactory: { retryFactory.makeConnection() })

    let pong = try await retryingClient.ping(timeout: .seconds(1))
    #expect(pong.processID == 22)
    #expect(retryFactory.makeCount == 2)

    let nonIdempotentConnection = MockScreenshotServiceConnection { connection, _, _, _ in
        connection.interrupt()
    }
    let nonIdempotentFactory = MockScreenshotConnectionFactory([nonIdempotentConnection])
    let nonRetryingClient = ScreenshotClient(connectionFactory: { nonIdempotentFactory.makeConnection() })

    do {
        _ = try await nonRetryingClient.perform(
            action: .custom(name: "mutate", isIdempotent: false),
            timeout: .seconds(1)
        )
        Issue.record("非幂等请求被中断后不应重放")
    } catch let error as ScreenshotFeatureError {
        #expect(error == .serviceInterrupted)
    }
    #expect(nonIdempotentFactory.makeCount == 1)
}

@Test func screenshotClientIsolatesAfterThreeFailuresAndHealthCheckRecovers() async throws {
    let connection = MockScreenshotServiceConnection { _, data, reply, _ in
        let request = try! JSONDecoder().decode(ScreenshotServiceRequest.self, from: data)
        let payload: ScreenshotServiceResponsePayload = request.action == .health
            ? .health(.init(processID: 33, activeRequestCount: 0))
            : .failure(.internalFailure("fixture failure"))
        reply(try! makeResponse(for: data, payload: payload))
    }
    let client = ScreenshotClient(connectionFactory: { connection })

    for _ in 0..<3 {
        do {
            _ = try await client.perform(
                action: .custom(name: "unstable", isIdempotent: false),
                timeout: .seconds(1)
            )
            Issue.record("服务失败响应不应成功")
        } catch { }
    }
    #expect(await client.healthState == .isolated(consecutiveFailures: 3))

    let health = try await client.healthCheck(timeout: .seconds(1))
    #expect(health.processID == 33)
    #expect(await client.healthState == .healthy)
}

@Test func screenshotClientCountsOnlyConsecutiveFailures() async {
    let connection = MockScreenshotServiceConnection { _, data, reply, _ in
        let request = try! JSONDecoder().decode(ScreenshotServiceRequest.self, from: data)
        let payload: ScreenshotServiceResponsePayload = request.action == .ping
            ? .pong(.init(processID: 44))
            : .failure(.internalFailure("fixture failure"))
        reply(try! makeResponse(for: data, payload: payload))
    }
    let client = ScreenshotClient(connectionFactory: { connection })

    await performExpectedFailure(on: client)
    await performExpectedFailure(on: client)
    _ = try? await client.ping(timeout: .seconds(1))
    await performExpectedFailure(on: client)
    await performExpectedFailure(on: client)
    #expect(await client.healthState == .healthy)

    await performExpectedFailure(on: client)
    #expect(await client.healthState == .isolated(consecutiveFailures: 3))
}

@Test func screenshotClientTreatsUnexpectedTypedPayloadAsFailure() async {
    let connection = MockScreenshotServiceConnection { _, data, reply, _ in
        reply(try! makeResponse(
            for: data,
            payload: .health(.init(processID: 45, activeRequestCount: 0))
        ))
    }
    let client = ScreenshotClient(connectionFactory: { connection })

    for _ in 0..<3 {
        do {
            _ = try await client.ping(timeout: .seconds(1))
            Issue.record("ping 收到 health payload 时不应成功")
        } catch let error as ScreenshotFeatureError {
            #expect(error == .serviceFailed(message: "ping returned an unexpected payload"))
        } catch {
            Issue.record("收到非预期错误类型：\(error)")
        }
    }

    #expect(await client.healthState == .isolated(consecutiveFailures: 3))
}

@Test func screenshotClientCancellationCancelsPendingRequest() async {
    let connection = MockScreenshotServiceConnection { _, _, _, _ in }
    let client = ScreenshotClient(connectionFactory: { connection })
    let request = Task {
        try await client.ping(timeout: .seconds(1))
    }

    request.cancel()
    do {
        _ = try await request.value
        Issue.record("取消后的请求不应成功")
    } catch let error as ScreenshotFeatureError {
        #expect(error == .cancelled)
    } catch {
        Issue.record("收到非预期错误类型：\(error)")
    }
    #expect(connection.cancelledRequestIDs.count == 1)
    #expect(await client.healthState == .healthy)
}

@Test func screenshotClientShutdownCancelsPendingRequestsAndAllowsFreshConnection() async throws {
    let pendingConnection = MockScreenshotServiceConnection { _, _, _, _ in }
    let freshConnection = MockScreenshotServiceConnection { _, data, reply, _ in
        reply(try! makeResponse(for: data, payload: .pong(.init(processID: 55))))
    }
    let factory = MockScreenshotConnectionFactory([pendingConnection, freshConnection])
    let client = ScreenshotClient(connectionFactory: { factory.makeConnection() })
    let pendingRequest = Task {
        try await client.ping(timeout: .seconds(1))
    }

    for _ in 0..<1_000 where pendingConnection.performCount == 0 {
        await Task.yield()
    }
    #expect(pendingConnection.performCount == 1)

    await client.shutdown()

    do {
        _ = try await pendingRequest.value
        Issue.record("关闭客户端后，未完成请求不应成功")
    } catch let error as ScreenshotFeatureError {
        #expect(error == .cancelled)
    } catch {
        Issue.record("收到非预期错误类型：\(error)")
    }
    #expect(pendingConnection.invalidateCount == 1)
    #expect(await client.healthState == .healthy)

    let pong = try await client.ping(timeout: .seconds(1))
    #expect(pong.processID == 55)
    #expect(factory.makeCount == 2)
    #expect(freshConnection.performCount == 1)
}

@Test func xpcInterfaceAllowListContainsOnlyApprovedFoundationClasses() {
    let approved = Set(["NSData", "NSString", "NSNumber", "NSArray", "NSDictionary"])
    #expect(ScreenshotXPCInterface.allowedSecureCodingClassNames.isSubset(of: approved))
    #expect(!ScreenshotXPCInterface.allowedSecureCodingClassNames.contains("NSURL"))
}

private func performExpectedFailure(on client: ScreenshotClient) async {
    do {
        _ = try await client.perform(
            action: .custom(name: "unstable", isIdempotent: false),
            timeout: .seconds(1)
        )
        Issue.record("服务失败响应不应成功")
    } catch { }
}

private func makeResponse(
    for requestData: Data,
    payload: ScreenshotServiceResponsePayload
) throws -> Data {
    let request = try JSONDecoder().decode(ScreenshotServiceRequest.self, from: requestData)
    return try JSONEncoder().encode(
        ScreenshotServiceResponse(requestID: request.id, payload: payload)
    )
}

private final class MockScreenshotConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [MockScreenshotServiceConnection]
    private(set) var makeCount = 0

    init(_ connections: [MockScreenshotServiceConnection]) {
        self.connections = connections
    }

    func makeConnection() -> any ScreenshotServiceConnection {
        lock.withLock {
            makeCount += 1
            precondition(!connections.isEmpty, "测试连接工厂已耗尽")
            return connections.removeFirst()
        }
    }
}

private final class MockScreenshotServiceConnection: ScreenshotServiceConnection, @unchecked Sendable {
    typealias Handler = @Sendable (
        MockScreenshotServiceConnection,
        Data,
        @escaping @Sendable (Data) -> Void,
        @escaping @Sendable (Error) -> Void
    ) -> Void

    private let lock = NSLock()
    private let handler: Handler
    private var storedInterruptionHandler: (@Sendable () -> Void)?
    private var storedInvalidationHandler: (@Sendable () -> Void)?
    private var storedCancelledRequestIDs: [String] = []
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

    var performCount: Int { lock.withLock { storedPerformCount } }
    var invalidateCount: Int { lock.withLock { storedInvalidateCount } }
    var cancelledRequestIDs: [String] { lock.withLock { storedCancelledRequestIDs } }

    func resume() { }

    func perform(
        requestData: Data,
        reply: @escaping @Sendable (Data) -> Void,
        failure: @escaping @Sendable (Error) -> Void
    ) {
        lock.withLock { storedPerformCount += 1 }
        handler(self, requestData, reply, failure)
    }

    func cancel(requestID: String) {
        lock.withLock { storedCancelledRequestIDs.append(requestID) }
    }

    func invalidate() {
        lock.withLock { storedInvalidateCount += 1 }
    }

    func interrupt() {
        let handler = lock.withLock { storedInterruptionHandler }
        handler?()
    }
}

@Test func screenshotClientSendsCapturePayloadAndDecodesArtifactMetadata() async throws {
    let artifact = ScreenshotArtifact(
        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        captureMode: .fullScreen,
        relativePath: "Captures/2026/07/capture.png",
        thumbnailRelativePath: nil,
        pointSize: .init(width: 100, height: 50),
        pixelSize: .init(width: 200, height: 100),
        uniformTypeIdentifier: "public.png",
        sha256: "abc123",
        displays: []
    )
    let request = ScreenshotCaptureRequest(
        mode: .fullScreen,
        target: .display(displayID: 9)
    )
    let connection = MockScreenshotServiceConnection { _, data, reply, _ in
        let serviceRequest = try! JSONDecoder().decode(ScreenshotServiceRequest.self, from: data)
        #expect(serviceRequest.action.name == "capture")
        #expect(serviceRequest.action.isIdempotent == false)
        let decodedRequest = try! JSONDecoder().decode(
            ScreenshotCaptureRequest.self,
            from: serviceRequest.action.payload!
        )
        #expect(decodedRequest == request)
        reply(try! makeResponse(
            for: data,
            payload: .capture(try! JSONEncoder().encode(artifact))
        ))
    }
    let client = ScreenshotClient(connectionFactory: { connection })

    let received = try await client.capture(request, timeout: .seconds(1))

    #expect(received == artifact)
}

@Test func screenshotClientSendsColorSamplePayloadAndDecodesSample() async throws {
    let request = ScreenshotColorSampleRequest(
        displayID: 9,
        desktopPoint: .init(x: 42.5, y: 18.25),
        loupePixelDiameter: 11
    )
    let sample = ScreenshotColorSample(
        color: .init(red: 12, green: 34, blue: 56),
        loupeRGBA: Data([12, 34, 56, 255]),
        loupePixelSize: .init(width: 1, height: 1),
        centerPixel: .init(x: 0, y: 0)
    )
    let connection = MockScreenshotServiceConnection { _, data, reply, _ in
        let serviceRequest = try! JSONDecoder().decode(ScreenshotServiceRequest.self, from: data)
        #expect(serviceRequest.action.name == "sampleColor")
        #expect(serviceRequest.action.isIdempotent)
        #expect(try! JSONDecoder().decode(
            ScreenshotColorSampleRequest.self,
            from: serviceRequest.action.payload!
        ) == request)
        reply(try! makeResponse(
            for: data,
            payload: .colorSample(try! JSONEncoder().encode(sample))
        ))
    }
    let client = ScreenshotClient(connectionFactory: { connection })

    #expect(try await client.sampleColor(request, timeout: .seconds(1)) == sample)
}

@Test func screenshotClientSendsRecognitionPayloadAndDecodesResult() async throws {
    let artifact = ScreenshotArtifact(
        id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
        createdAt: Date(timeIntervalSince1970: 1_700_000_100),
        captureMode: .ocrRegion,
        relativePath: "Captures/2026/07/ocr.png",
        thumbnailRelativePath: nil,
        pointSize: .init(width: 500, height: 300),
        pixelSize: .init(width: 1_000, height: 600),
        uniformTypeIdentifier: "public.png",
        sha256: "ocr-fixture",
        displays: []
    )
    let request = ScreenshotRecognitionRequest(
        artifact: artifact,
        configuration: .init(recognitionLanguages: ["zh-Hans", "en-US"], minimumTextConfidence: 0.4)
    )
    let result = ScreenshotRecognitionResult(
        artifactID: artifact.id,
        fullText: "你好 Touch",
        textBlocks: [.init(
            text: "你好 Touch",
            confidence: 0.95,
            normalizedBounds: .init(x: 0.1, y: 0.2, width: 0.8, height: 0.2)
        )],
        barcodes: []
    )
    let connection = MockScreenshotServiceConnection { _, data, reply, _ in
        let serviceRequest = try! JSONDecoder().decode(ScreenshotServiceRequest.self, from: data)
        #expect(serviceRequest.action.name == "recognize")
        #expect(serviceRequest.action.isIdempotent)
        #expect(try! JSONDecoder().decode(
            ScreenshotRecognitionRequest.self,
            from: serviceRequest.action.payload!
        ) == request)
        reply(try! makeResponse(
            for: data,
            payload: .recognition(try! JSONEncoder().encode(result))
        ))
    }
    let client = ScreenshotClient(connectionFactory: { connection })

    #expect(try await client.recognize(request, timeout: .seconds(1)) == result)
}
