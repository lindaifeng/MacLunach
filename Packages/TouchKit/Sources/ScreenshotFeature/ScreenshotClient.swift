import Foundation
import ScreenshotServiceProtocol

public protocol ScreenshotServiceConnection: AnyObject, Sendable {
    var interruptionHandler: (@Sendable () -> Void)? { get set }
    var invalidationHandler: (@Sendable () -> Void)? { get set }

    func resume()
    func perform(
        requestData: Data,
        reply: @escaping @Sendable (Data) -> Void,
        failure: @escaping @Sendable (Error) -> Void
    )
    func cancel(requestID: String)
    func invalidate()
}

public enum ScreenshotClientHealthState: Equatable, Sendable {
    case healthy
    case isolated(consecutiveFailures: Int)
}

public actor ScreenshotClient {
    public typealias ConnectionFactory = @Sendable () -> any ScreenshotServiceConnection

    private struct ConnectionRecord {
        let id: ObjectIdentifier
        let connection: any ScreenshotServiceConnection
    }

    private struct PendingRequest {
        let connectionID: ObjectIdentifier
        let continuation: CheckedContinuation<ScreenshotServiceResponse, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private let connectionFactory: ConnectionFactory
    private var connectionRecord: ConnectionRecord?
    private var pendingRequests: [UUID: PendingRequest] = [:]
    private var consecutiveFailures = 0

    public private(set) var healthState: ScreenshotClientHealthState = .healthy

    public init(connectionFactory: @escaping ConnectionFactory) {
        self.connectionFactory = connectionFactory
    }

    public init(serviceName: String = ScreenshotXPCInterface.serviceName) {
        self.connectionFactory = {
            LiveScreenshotServiceConnection(serviceName: serviceName)
        }
    }

    /// Closes the private XPC connection and finishes every outstanding request.
    /// A later request can establish a fresh connection after the feature is enabled again.
    public func shutdown() {
        let connection = connectionRecord?.connection
        connectionRecord = nil
        connection?.invalidate()

        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for request in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: ScreenshotFeatureError.cancelled)
        }

        consecutiveFailures = 0
        healthState = .healthy
    }

    public func ping(timeout: Duration = .seconds(2)) async throws -> ScreenshotPong {
        let payload = try await perform(action: .ping, timeout: timeout)
        guard case let .pong(pong) = payload else {
            throw ScreenshotFeatureError.serviceFailed(message: "ping returned an unexpected payload")
        }
        return pong
    }

    public func healthCheck(timeout: Duration = .seconds(2)) async throws -> ScreenshotServiceHealth {
        let payload = try await perform(action: .health, timeout: timeout, permitsIsolation: true)
        guard case let .health(health) = payload else {
            throw ScreenshotFeatureError.serviceFailed(message: "health returned an unexpected payload")
        }
        return health
    }

    public func availableSelectionContent(
        timeout: Duration = .seconds(10)
    ) async throws -> ScreenshotSelectionContent {
        let payload = try await perform(action: .availableContent, timeout: timeout)
        guard case let .availableContent(contentData) = payload else {
            throw ScreenshotFeatureError.serviceFailed(
                message: "availableContent returned an unexpected payload"
            )
        }
        do {
            return try JSONDecoder().decode(ScreenshotSelectionContent.self, from: contentData)
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "available content decoding failed: \(error)"
            )
        }
    }

    public func capture(
        _ request: ScreenshotCaptureRequest,
        timeout: Duration = .seconds(30)
    ) async throws -> ScreenshotArtifact {
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "capture request encoding failed: \(error)"
            )
        }
        let payload = try await perform(
            action: .capture(requestData: requestData),
            timeout: timeout
        )
        guard case let .capture(artifactData) = payload else {
            throw ScreenshotFeatureError.serviceFailed(
                message: "capture returned an unexpected payload"
            )
        }
        do {
            return try JSONDecoder().decode(ScreenshotArtifact.self, from: artifactData)
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "capture artifact decoding failed: \(error)"
            )
        }
    }

    public func sampleColor(
        _ request: ScreenshotColorSampleRequest,
        timeout: Duration = .seconds(5)
    ) async throws -> ScreenshotColorSample {
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "color sample request encoding failed: \(error)"
            )
        }
        let payload = try await perform(
            action: .sampleColor(requestData: requestData),
            timeout: timeout
        )
        guard case let .colorSample(sampleData) = payload else {
            throw ScreenshotFeatureError.serviceFailed(
                message: "sampleColor returned an unexpected payload"
            )
        }
        do {
            return try JSONDecoder().decode(ScreenshotColorSample.self, from: sampleData)
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "color sample decoding failed: \(error)"
            )
        }
    }

    public func recognize(
        _ request: ScreenshotRecognitionRequest,
        timeout: Duration = .seconds(30)
    ) async throws -> ScreenshotRecognitionResult {
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "recognition request encoding failed: \(error)"
            )
        }
        let payload = try await perform(
            action: .recognize(requestData: requestData),
            timeout: timeout
        )
        guard case let .recognition(resultData) = payload else {
            throw ScreenshotFeatureError.serviceFailed(
                message: "recognize returned an unexpected payload"
            )
        }
        do {
            return try JSONDecoder().decode(ScreenshotRecognitionResult.self, from: resultData)
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "recognition result decoding failed: \(error)"
            )
        }
    }

    public func exportArtifact(
        _ artifact: ScreenshotArtifact,
        to destinationURL: URL,
        timeout: Duration = .seconds(30)
    ) async throws -> URL {
        let request = ScreenshotArtifactExportRequest(
            artifact: artifact,
            destinationURL: destinationURL
        )
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "artifact export request encoding failed: \(error)"
            )
        }
        let payload = try await perform(
            action: .exportArtifact(requestData: requestData),
            timeout: timeout
        )
        guard case let .artifactExport(resultData) = payload else {
            throw ScreenshotFeatureError.serviceFailed(
                message: "exportArtifact returned an unexpected payload"
            )
        }
        do {
            return try JSONDecoder().decode(
                ScreenshotArtifactExportResult.self,
                from: resultData
            ).destinationURL
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "artifact export result decoding failed: \(error)"
            )
        }
    }

    public func deleteArtifact(
        _ artifact: ScreenshotArtifact,
        timeout: Duration = .seconds(10)
    ) async throws {
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(
                ScreenshotArtifactDeletionRequest(artifact: artifact)
            )
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "artifact deletion request encoding failed: \(error)"
            )
        }
        let payload = try await perform(
            action: .deleteArtifact(requestData: requestData),
            timeout: timeout
        )
        guard case .artifactDeleted = payload else {
            throw ScreenshotFeatureError.serviceFailed(
                message: "deleteArtifact returned an unexpected payload"
            )
        }
    }

    public func registerArtifact(
        _ artifact: ScreenshotArtifact,
        history: ScreenshotHistoryConfiguration,
        timeout: Duration = .seconds(10)
    ) async throws {
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(
                ScreenshotArtifactRegistrationRequest(artifact: artifact, history: history)
            )
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "artifact registration request encoding failed: \(error)"
            )
        }
        let payload = try await perform(
            action: .registerArtifact(requestData: requestData),
            timeout: timeout
        )
        guard case .artifactRegistered = payload else {
            throw ScreenshotFeatureError.serviceFailed(
                message: "registerArtifact returned an unexpected payload"
            )
        }
    }

    public func saveAnnotationProject(
        _ document: AnnotationDocument,
        timeout: Duration = .seconds(10)
    ) async throws -> String {
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(AnnotationProjectSaveRequest(document: document))
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "annotation project save request encoding failed: \(error)"
            )
        }
        let payload = try await perform(
            action: .saveAnnotationProject(requestData: requestData),
            timeout: timeout
        )
        guard case let .annotationProjectSaved(resultData) = payload else {
            throw ScreenshotFeatureError.serviceFailed(
                message: "saveAnnotationProject returned an unexpected payload"
            )
        }
        do {
            return try JSONDecoder().decode(
                AnnotationProjectSaveResult.self,
                from: resultData
            ).relativePath
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "annotation project save result decoding failed: \(error)"
            )
        }
    }

    public func loadAnnotationProject(
        relativePath: String,
        fallbackDocument: AnnotationDocument,
        timeout: Duration = .seconds(10)
    ) async throws -> AnnotationProjectLoadResult {
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(AnnotationProjectLoadRequest(
                relativePath: relativePath,
                fallbackDocument: fallbackDocument
            ))
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "annotation project load request encoding failed: \(error)"
            )
        }
        let payload = try await perform(
            action: .loadAnnotationProject(requestData: requestData),
            timeout: timeout
        )
        guard case let .annotationProjectLoaded(resultData) = payload else {
            throw ScreenshotFeatureError.serviceFailed(
                message: "loadAnnotationProject returned an unexpected payload"
            )
        }
        do {
            return try JSONDecoder().decode(AnnotationProjectLoadResult.self, from: resultData)
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "annotation project load result decoding failed: \(error)"
            )
        }
    }

    public func exportAnnotationDocument(
        _ document: AnnotationDocument,
        to destinationURL: URL,
        output: ScreenshotOutputOptions,
        allowsOverwrite: Bool = false,
        timeout: Duration = .seconds(30)
    ) async throws -> URL {
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(AnnotationDocumentExportRequest(
                document: document,
                destinationURL: destinationURL,
                output: output,
                allowsOverwrite: allowsOverwrite
            ))
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "annotation document export request encoding failed: \(error)"
            )
        }
        let payload = try await perform(
            action: .exportAnnotationDocument(requestData: requestData),
            timeout: timeout
        )
        guard case let .annotationDocumentExported(resultData) = payload else {
            throw ScreenshotFeatureError.serviceFailed(
                message: "exportAnnotationDocument returned an unexpected payload"
            )
        }
        do {
            return try JSONDecoder().decode(
                AnnotationDocumentExportResult.self,
                from: resultData
            ).destinationURL
        } catch {
            throw ScreenshotFeatureError.serviceFailed(
                message: "annotation document export result decoding failed: \(error)"
            )
        }
    }

    public func perform(
        action: ScreenshotServiceAction,
        timeout: Duration = .seconds(2)
    ) async throws -> ScreenshotServiceResponsePayload {
        try await perform(action: action, timeout: timeout, permitsIsolation: false)
    }

    private func perform(
        action: ScreenshotServiceAction,
        timeout: Duration,
        permitsIsolation: Bool
    ) async throws -> ScreenshotServiceResponsePayload {
        if !permitsIsolation, case .isolated = healthState {
            throw ScreenshotFeatureError.serviceIsolated
        }

        let request = ScreenshotServiceRequest(action: action)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            let response: ScreenshotServiceResponse
            do {
                response = try await performAttempt(request: request, timeout: timeout)
            } catch let error as ScreenshotFeatureError
                where error == .serviceInterrupted && action.isIdempotent {
                // launchd may still be retiring the crashed service when interruption arrives.
                // A bounded backoff lets a fresh embedded-service instance become launchable.
                var remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else {
                    throw ScreenshotFeatureError.serviceTimedOut
                }
                do {
                    try await Task.sleep(for: min(remaining, .milliseconds(100)))
                } catch {
                    throw ScreenshotFeatureError.cancelled
                }
                remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else {
                    throw ScreenshotFeatureError.serviceTimedOut
                }
                response = try await performAttempt(request: request, timeout: remaining)
            }

            let payload = try validatedPayload(from: response, expectedRequestID: request.id)
            try validate(payload: payload, for: action)
            consecutiveFailures = 0
            healthState = .healthy
            return payload
        } catch {
            let featureError = normalize(error)
            if featureError != .cancelled {
                recordFailure()
            }
            throw featureError
        }
    }

    private func performAttempt(
        request: ScreenshotServiceRequest,
        timeout: Duration
    ) async throws -> ScreenshotServiceResponse {
        let record = makeConnectionIfNeeded()
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            throw ScreenshotFeatureError.serviceFailed(message: "request encoding failed: \(error)")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.requestTimedOut(
                        requestID: request.id,
                        connectionID: record.id
                    )
                }
                pendingRequests[request.id] = PendingRequest(
                    connectionID: record.id,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                if Task<Never, Never>.isCancelled {
                    Task { [weak self] in
                        await self?.cancelRequest(
                            requestID: request.id,
                            connectionID: record.id
                        )
                    }
                }

                record.connection.perform(
                    requestData: requestData,
                    reply: { [weak self] data in
                        guard let self else { return }
                        Task {
                            await self.receiveReply(
                                data,
                                requestID: request.id,
                                connectionID: record.id
                            )
                        }
                    },
                    failure: { [weak self] _ in
                        guard let self else { return }
                        Task {
                            await self.connectionFailed(connectionID: record.id)
                        }
                    }
                )
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(requestID: request.id, connectionID: record.id)
            }
        }
    }

    private func makeConnectionIfNeeded() -> ConnectionRecord {
        if let connectionRecord {
            return connectionRecord
        }

        let connection = connectionFactory()
        let id = ObjectIdentifier(connection)
        connection.interruptionHandler = { [weak self] in
            guard let self else { return }
            Task { await self.connectionInterrupted(connectionID: id) }
        }
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            Task { await self.connectionInterrupted(connectionID: id) }
        }
        connection.resume()

        let record = ConnectionRecord(id: id, connection: connection)
        connectionRecord = record
        return record
    }

    private func receiveReply(
        _ data: Data,
        requestID: UUID,
        connectionID: ObjectIdentifier
    ) {
        guard let pending = takePending(requestID: requestID, connectionID: connectionID) else {
            return
        }

        do {
            let response = try JSONDecoder().decode(ScreenshotServiceResponse.self, from: data)
            pending.continuation.resume(returning: response)
        } catch {
            pending.continuation.resume(throwing: ScreenshotFeatureError.serviceFailed(
                message: "response decoding failed: \(error)"
            ))
        }
    }

    private func requestTimedOut(requestID: UUID, connectionID: ObjectIdentifier) {
        guard let pending = takePending(requestID: requestID, connectionID: connectionID) else {
            return
        }
        if connectionRecord?.id == connectionID {
            let connection = connectionRecord?.connection
            connectionRecord = nil
            connection?.cancel(requestID: requestID.uuidString)
            connection?.invalidate()
        }
        pending.continuation.resume(throwing: ScreenshotFeatureError.serviceTimedOut)
    }

    private func cancelRequest(requestID: UUID, connectionID: ObjectIdentifier) {
        guard let pending = takePending(requestID: requestID, connectionID: connectionID) else {
            return
        }
        if connectionRecord?.id == connectionID {
            connectionRecord?.connection.cancel(requestID: requestID.uuidString)
        }
        pending.continuation.resume(throwing: ScreenshotFeatureError.cancelled)
    }

    private func connectionFailed(connectionID: ObjectIdentifier) {
        finishConnection(connectionID: connectionID, error: .serviceInterrupted)
    }

    private func connectionInterrupted(connectionID: ObjectIdentifier) {
        finishConnection(connectionID: connectionID, error: .serviceInterrupted)
    }

    private func finishConnection(
        connectionID: ObjectIdentifier,
        error: ScreenshotFeatureError
    ) {
        if connectionRecord?.id == connectionID {
            let interruptedConnection = connectionRecord?.connection
            connectionRecord = nil
            interruptedConnection?.invalidate()
        }
        let requestIDs = pendingRequests.compactMap { requestID, pending in
            pending.connectionID == connectionID ? requestID : nil
        }
        for requestID in requestIDs {
            guard let pending = pendingRequests.removeValue(forKey: requestID) else { continue }
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
    }

    private func takePending(
        requestID: UUID,
        connectionID: ObjectIdentifier
    ) -> PendingRequest? {
        guard pendingRequests[requestID]?.connectionID == connectionID,
              let pending = pendingRequests.removeValue(forKey: requestID) else {
            return nil
        }
        pending.timeoutTask.cancel()
        return pending
    }

    private func validatedPayload(
        from response: ScreenshotServiceResponse,
        expectedRequestID: UUID
    ) throws -> ScreenshotServiceResponsePayload {
        guard response.requestID == expectedRequestID else {
            throw ScreenshotFeatureError.responseMismatch(
                expected: expectedRequestID,
                received: response.requestID
            )
        }
        guard response.protocolVersion == ScreenshotServiceProtocolVersion.current else {
            throw ScreenshotFeatureError.incompatibleProtocol(
                expected: ScreenshotServiceProtocolVersion.current,
                received: response.protocolVersion
            )
        }

        if case let .failure(failure) = response.payload {
            throw map(failure)
        }
        return response.payload
    }

    private func validate(
        payload: ScreenshotServiceResponsePayload,
        for action: ScreenshotServiceAction
    ) throws {
        switch action.name {
        case ScreenshotServiceAction.ping.name:
            guard case .pong = payload else {
                throw ScreenshotFeatureError.serviceFailed(
                    message: "ping returned an unexpected payload"
                )
            }
        case ScreenshotServiceAction.health.name:
            guard case .health = payload else {
                throw ScreenshotFeatureError.serviceFailed(
                    message: "health returned an unexpected payload"
                )
            }
        case ScreenshotServiceAction.availableContent.name:
            guard case .availableContent = payload else {
                throw ScreenshotFeatureError.serviceFailed(
                    message: "availableContent returned an unexpected payload"
                )
            }
        case "capture":
            guard case .capture = payload else {
                throw ScreenshotFeatureError.serviceFailed(
                    message: "capture returned an unexpected payload"
                )
            }
        case "sampleColor":
            guard case .colorSample = payload else {
                throw ScreenshotFeatureError.serviceFailed(
                    message: "sampleColor returned an unexpected payload"
                )
            }
        case "recognize":
            guard case .recognition = payload else {
                throw ScreenshotFeatureError.serviceFailed(
                    message: "recognize returned an unexpected payload"
                )
            }
        case "exportArtifact":
            guard case .artifactExport = payload else {
                throw ScreenshotFeatureError.serviceFailed(
                    message: "exportArtifact returned an unexpected payload"
                )
            }
        case "deleteArtifact":
            guard case .artifactDeleted = payload else {
                throw ScreenshotFeatureError.serviceFailed(
                    message: "deleteArtifact returned an unexpected payload"
                )
            }
        case "saveAnnotationProject":
            guard case .annotationProjectSaved = payload else {
                throw ScreenshotFeatureError.serviceFailed(
                    message: "saveAnnotationProject returned an unexpected payload"
                )
            }
        case "loadAnnotationProject":
            guard case .annotationProjectLoaded = payload else {
                throw ScreenshotFeatureError.serviceFailed(
                    message: "loadAnnotationProject returned an unexpected payload"
                )
            }
        default:
            break
        }
    }

    private func map(_ failure: ScreenshotServiceFailure) -> ScreenshotFeatureError {
        switch failure {
        case let .incompatibleProtocol(expected, received):
            return .incompatibleProtocol(expected: expected, received: received)
        case let .unsupportedAction(action):
            return .unsupportedAction(action: action)
        case let .malformedRequest(message), let .internalFailure(message):
            return .serviceFailed(message: message)
        case .cancelled:
            return .cancelled
        case .permissionDenied:
            return .permissionDenied
        case .noDisplayAvailable:
            return .noDisplayAvailable
        case .targetUnavailable:
            return .targetUnavailable
        case .encodingFailed:
            return .encodingFailed
        case let .recognitionFailed(message):
            return .recognitionFailed(message: message)
        case let .storageFailed(message):
            return .storageFailed(message: message)
        }
    }

    private func normalize(_ error: any Error) -> ScreenshotFeatureError {
        if let featureError = error as? ScreenshotFeatureError {
            return featureError
        }
        return .serviceFailed(message: String(describing: error))
    }

    private func recordFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= 3 {
            healthState = .isolated(consecutiveFailures: consecutiveFailures)
        }
    }
}

public final class LiveScreenshotServiceConnection: ScreenshotServiceConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NSXPCConnection
    private var storedInterruptionHandler: (@Sendable () -> Void)?
    private var storedInvalidationHandler: (@Sendable () -> Void)?

    public init(serviceName: String = ScreenshotXPCInterface.serviceName) {
        connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = ScreenshotXPCInterface.make()
        connection.interruptionHandler = { [weak self] in
            self?.emitInterruption()
        }
        connection.invalidationHandler = { [weak self] in
            self?.emitInvalidation()
        }
    }

    public var interruptionHandler: (@Sendable () -> Void)? {
        get { lock.withLock { storedInterruptionHandler } }
        set { lock.withLock { storedInterruptionHandler = newValue } }
    }

    public var invalidationHandler: (@Sendable () -> Void)? {
        get { lock.withLock { storedInvalidationHandler } }
        set { lock.withLock { storedInvalidationHandler = newValue } }
    }

    public func resume() {
        connection.resume()
    }

    public func perform(
        requestData: Data,
        reply: @escaping @Sendable (Data) -> Void,
        failure: @escaping @Sendable (Error) -> Void
    ) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(failure)
            as? ScreenshotXPCProtocol else {
            failure(ScreenshotFeatureError.serviceInterrupted)
            return
        }
        proxy.perform(requestData: requestData, reply: reply)
    }

    public func cancel(requestID: String) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in })
            as? ScreenshotXPCProtocol else {
            return
        }
        proxy.cancel(requestID: requestID)
    }

    public func invalidate() {
        connection.invalidate()
    }

    private func emitInterruption() {
        let handler = lock.withLock { storedInterruptionHandler }
        handler?()
    }

    private func emitInvalidation() {
        let handler = lock.withLock { storedInvalidationHandler }
        handler?()
    }
}
