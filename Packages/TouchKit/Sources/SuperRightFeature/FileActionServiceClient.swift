import AppKit
import Foundation
import FileActionServiceProtocol

public protocol FileActionServiceConnection: AnyObject, Sendable {
    var interruptionHandler: (@Sendable () -> Void)? { get set }
    var invalidationHandler: (@Sendable () -> Void)? { get set }

    func resume()
    func perform(
        requestData: Data,
        reply: @escaping @Sendable (Data) -> Void,
        failure: @escaping @Sendable (any Error) -> Void
    )
    func invalidate()
}

public enum FileActionServiceClientError: Error, Equatable, Sendable {
    case timedOut
    case interrupted
    case cancelled
    case responseDecodingFailed(String)
    case responseMismatch(expected: UUID, received: UUID?)
    case incompatibleProtocol(expected: Int, received: Int)
    case serviceFailure(FileActionServiceFailure)
    case unexpectedPayload
}

public actor FileActionServiceClient {
    public typealias ConnectionFactory = @Sendable () -> any FileActionServiceConnection

    private struct ConnectionRecord {
        let id: ObjectIdentifier
        let connection: any FileActionServiceConnection
    }

    private struct PendingRequest {
        let connectionID: ObjectIdentifier
        let continuation: CheckedContinuation<FileActionServiceResponse, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private let connectionFactory: ConnectionFactory
    private var connectionRecord: ConnectionRecord?
    private var pendingRequests: [UUID: PendingRequest] = [:]

    public init(connectionFactory: @escaping ConnectionFactory) {
        self.connectionFactory = connectionFactory
    }

    public init(serviceName: String = FileActionServiceXPCInterface.serviceName) {
        connectionFactory = {
            LiveFileActionServiceConnection(serviceName: serviceName)
        }
    }

    public func ping(timeout: Duration = .seconds(1)) async throws -> FileActionServicePong {
        let request = FileActionServiceRequest(action: .ping)
        let response = try await perform(request, timeout: timeout)
        try validate(response, for: request)

        switch response.payload {
        case let .pong(pong):
            return pong
        case let .failure(failure):
            throw FileActionServiceClientError.serviceFailure(failure)
        case .actionResult:
            throw FileActionServiceClientError.unexpectedPayload
        }
    }

    public func perform(
        action: FileActionServiceAction,
        requestID: UUID = UUID(),
        timeout: Duration = .seconds(3)
    ) async throws -> FileActionServiceActionResult {
        let request = FileActionServiceRequest(id: requestID, action: action)
        return try await performAction(request, timeout: timeout)
    }

    public func createFile(
        in directory: URL,
        displayName: String,
        fileExtension: String,
        initialContent: String?,
        timeout: Duration = .seconds(3)
    ) async throws -> URL {
        let result = try await perform(
            action: .createFile(
                directory: directory,
                displayName: displayName,
                fileExtension: fileExtension,
                initialContent: initialContent
            ),
            timeout: timeout
        )
        guard let createdURL = result.createdURL else {
            throw FileActionServiceClientError.unexpectedPayload
        }
        return createdURL
    }

    public func createFolder(
        in directory: URL,
        timeout: Duration = .seconds(3)
    ) async throws -> URL {
        let result = try await perform(
            action: .createFolder(directory: directory),
            timeout: timeout
        )
        guard let createdURL = result.createdURL else {
            throw FileActionServiceClientError.unexpectedPayload
        }
        return createdURL
    }

    public func openTerminal(
        at directory: URL,
        preferredBundleIdentifier: String,
        timeout: Duration = .seconds(3)
    ) async throws -> String {
        let result = try await perform(
            action: .openTerminal(
                directory: directory,
                preferredBundleIdentifier: preferredBundleIdentifier
            ),
            timeout: timeout
        )
        guard let bundleIdentifier = result.openedApplicationBundleIdentifier else {
            throw FileActionServiceClientError.unexpectedPayload
        }
        return bundleIdentifier
    }

    private func performAction(
        _ request: FileActionServiceRequest,
        timeout: Duration
    ) async throws -> FileActionServiceActionResult {
        let response = try await perform(request, timeout: timeout)
        try validate(response, for: request)
        switch response.payload {
        case let .actionResult(result):
            return result
        case let .failure(failure):
            throw FileActionServiceClientError.serviceFailure(failure)
        case .pong:
            throw FileActionServiceClientError.unexpectedPayload
        }
    }

    private func validate(
        _ response: FileActionServiceResponse,
        for request: FileActionServiceRequest
    ) throws {
        guard response.requestID == request.id else {
            throw FileActionServiceClientError.responseMismatch(
                expected: request.id,
                received: response.requestID
            )
        }
        guard response.protocolVersion == FileActionServiceProtocolVersion.current else {
            throw FileActionServiceClientError.incompatibleProtocol(
                expected: FileActionServiceProtocolVersion.current,
                received: response.protocolVersion
            )
        }
    }

    public func shutdown() {
        let connection = connectionRecord?.connection
        connectionRecord = nil
        connection?.invalidate()

        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for request in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: FileActionServiceClientError.cancelled)
        }
    }

    private func perform(
        _ request: FileActionServiceRequest,
        timeout: Duration
    ) async throws -> FileActionServiceResponse {
        let record = makeConnectionIfNeeded()
        let requestData = try JSONEncoder().encode(request)

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
                pendingRequests[request.id] = .init(
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
                        Task { await self.connectionInterrupted(connectionID: record.id) }
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
            pending.continuation.resume(
                returning: try JSONDecoder().decode(FileActionServiceResponse.self, from: data)
            )
        } catch {
            pending.continuation.resume(throwing: FileActionServiceClientError.responseDecodingFailed(
                String(describing: error)
            ))
        }
    }

    private func requestTimedOut(requestID: UUID, connectionID: ObjectIdentifier) {
        guard let pending = takePending(requestID: requestID, connectionID: connectionID) else {
            return
        }
        invalidateConnection(connectionID: connectionID)
        pending.continuation.resume(throwing: FileActionServiceClientError.timedOut)
    }

    private func cancelRequest(requestID: UUID, connectionID: ObjectIdentifier) {
        guard let pending = takePending(requestID: requestID, connectionID: connectionID) else {
            return
        }
        pending.continuation.resume(throwing: FileActionServiceClientError.cancelled)
    }

    private func connectionInterrupted(connectionID: ObjectIdentifier) {
        invalidateConnection(connectionID: connectionID)
        let requestIDs = pendingRequests.compactMap { requestID, pending in
            pending.connectionID == connectionID ? requestID : nil
        }
        for requestID in requestIDs {
            guard let pending = pendingRequests.removeValue(forKey: requestID) else { continue }
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: FileActionServiceClientError.interrupted)
        }
    }

    private func invalidateConnection(connectionID: ObjectIdentifier) {
        guard connectionRecord?.id == connectionID else { return }
        let connection = connectionRecord?.connection
        connectionRecord = nil
        connection?.invalidate()
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
}

public struct FileActionServiceRelayRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let action: FileActionServiceAction
    public let createdAt: Date
    public let expiresAt: Date

    private enum CodingKeys: String, CodingKey { case id, action, createdAt, expiresAt }

    public init(
        id: UUID = UUID(),
        action: FileActionServiceAction,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.action = action
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(12)
    }

    public func isExpired(at date: Date = Date()) -> Bool { date >= expiresAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        action = try container.decode(FileActionServiceAction.self, forKey: .action)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
            ?? createdAt.addingTimeInterval(12)
    }
}

/// Finder 扩展无法直接 bootstrap 主应用内嵌的 XPC Service。
/// Debug 构建也没有 App Group provisioning，因此使用 Finder 扩展自己的容器作为
/// 原子中继目录：扩展写请求，主应用无激活唤起后转交 FileActionService，再写回响应。
public enum FileActionServiceRelay {
    public static let notificationName = Notification.Name(
        "me.touch.launcher.file-action-relay-requested"
    )

    private static let hostBundleIdentifier = "me.touch.launcher"
    private static let rootDirectory = SuperRightConfigurationSnapshotStore.defaultURL
        .deletingLastPathComponent()
        .appendingPathComponent("ActionRelay", isDirectory: true)
    private static let requestDirectory = rootDirectory
        .appendingPathComponent("Requests", isDirectory: true)
    private static let responseDirectory = rootDirectory
        .appendingPathComponent("Responses", isDirectory: true)
    private static let cancellationDirectory = rootDirectory
        .appendingPathComponent("Cancellations", isDirectory: true)

    public static var hasPendingRequests: Bool {
        !pendingRequests().isEmpty
    }

    public static func perform(
        action: FileActionServiceAction,
        timeout: Duration = .seconds(6)
    ) async throws -> FileActionServiceActionResult {
        let request = FileActionServiceRelayRequest(action: action)
        try enqueue(request)
        notifyAndLaunchHost()
        let response = try await waitForResponse(requestID: request.id, timeout: timeout)

        guard response.requestID == request.id else {
            throw FileActionServiceClientError.responseMismatch(
                expected: request.id,
                received: response.requestID
            )
        }
        guard response.protocolVersion == FileActionServiceProtocolVersion.current else {
            throw FileActionServiceClientError.incompatibleProtocol(
                expected: FileActionServiceProtocolVersion.current,
                received: response.protocolVersion
            )
        }
        switch response.payload {
        case let .actionResult(result):
            return result
        case let .failure(failure):
            throw FileActionServiceClientError.serviceFailure(failure)
        case .pong:
            throw FileActionServiceClientError.unexpectedPayload
        }
    }

    public static func pendingRequests() -> [FileActionServiceRelayRequest] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: requestDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else {
                    quarantineRequest(at: url, reason: "无法读取请求文件")
                    return nil
                }
                do {
                    return try JSONDecoder().decode(FileActionServiceRelayRequest.self, from: data)
                } catch {
                    quarantineRequest(at: url, reason: "请求 JSON 解码失败：\(error.localizedDescription)")
                    return nil
                }
            }
    }

    public static func writeResponse(
        _ response: FileActionServiceResponse,
        for requestID: UUID
    ) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(response)
        try data.write(to: responseURL(for: requestID), options: .atomic)
    }

    public static func removeRequest(id: UUID) {
        try? FileManager.default.removeItem(at: requestURL(for: id))
    }

    public static func isCancelled(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: cancellationURL(for: id).path)
    }

    public static func requestIsPresent(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: requestURL(for: id).path)
    }

    public static func removeResponse(id: UUID) {
        try? FileManager.default.removeItem(at: responseURL(for: id))
    }

    private static func enqueue(_ request: FileActionServiceRelayRequest) throws {
        try ensureDirectories()
        cleanupStaleArtifacts()
        removeResponse(id: request.id)
        removeCancellation(id: request.id)
        let data = try JSONEncoder().encode(request)
        try data.write(to: requestURL(for: request.id), options: .atomic)
    }

    private static func waitForResponse(
        requestID: UUID,
        timeout: Duration
    ) async throws -> FileActionServiceResponse {
        var receivedResponse = false
        defer {
            removeRequest(id: requestID)
            if !receivedResponse {
                markCancelled(id: requestID)
            } else {
                removeCancellation(id: requestID)
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let url = responseURL(for: requestID)

        while clock.now < deadline {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: url),
               let response = try? JSONDecoder().decode(FileActionServiceResponse.self, from: data) {
                receivedResponse = true
                removeResponse(id: requestID)
                return response
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FileActionServiceClientError.timedOut
    }

    private static func notifyAndLaunchHost() {
        DistributedNotificationCenter.default().post(
            name: notificationName,
            object: nil,
            userInfo: nil
        )

        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: hostBundleIdentifier
        ) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { _, _ in }
    }

    private static func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: requestDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: responseDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cancellationDirectory,
            withIntermediateDirectories: true
        )
    }

    private static func markCancelled(id: UUID) {
        do {
            try ensureDirectories()
            try Data(Date().description.utf8).write(to: cancellationURL(for: id), options: .atomic)
        } catch {
            NSLog("无法写入 Finder 中继取消标记 %@：%@", id.uuidString, error.localizedDescription)
        }
    }

    static func removeCancellation(id: UUID) {
        try? FileManager.default.removeItem(at: cancellationURL(for: id))
    }

    private static func quarantineRequest(at url: URL, reason: String) {
        NSLog("丢弃损坏的 Finder 中继请求 %@：%@", url.lastPathComponent, reason)
        try? FileManager.default.removeItem(at: url)
    }

    private static func cleanupStaleArtifacts(maxAge: TimeInterval = 3_600) {
        let now = Date()
        for directory in [responseDirectory, cancellationDirectory] {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls {
                let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                guard let date, now.timeIntervalSince(date) > maxAge else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func requestURL(for id: UUID) -> URL {
        requestDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private static func responseURL(for id: UUID) -> URL {
        responseDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private static func cancellationURL(for id: UUID) -> URL {
        cancellationDirectory.appendingPathComponent("\(id.uuidString).cancel", isDirectory: false)
    }
}

public actor FileActionServiceRelayHost {
    private let client: FileActionServiceClient
    private var processedRequestIDs: [UUID: Date] = [:]

    public init(client: FileActionServiceClient = FileActionServiceClient()) {
        self.client = client
    }

    public func drainPendingRequests() async {
        while true {
            let requests = FileActionServiceRelay.pendingRequests()
            guard !requests.isEmpty else { return }
            pruneProcessedRequestIDs()

            for request in requests {
                guard processedRequestIDs[request.id] == nil else {
                    FileActionServiceRelay.removeRequest(id: request.id)
                    continue
                }
                processedRequestIDs[request.id] = Date()

                if request.isExpired() || FileActionServiceRelay.isCancelled(id: request.id) {
                    let response = FileActionServiceResponse(
                        requestID: request.id,
                        payload: .failure(.internalFailure(
                            request.isExpired() ? "中继请求已过期，未执行文件操作。" : "中继请求已取消，未执行文件操作。"
                        ))
                    )
                    try? FileActionServiceRelay.writeResponse(response, for: request.id)
                    FileActionServiceRelay.removeRequest(id: request.id)
                    FileActionServiceRelay.removeCancellation(id: request.id)
                    continue
                }

                guard FileActionServiceRelay.requestIsPresent(id: request.id),
                      !FileActionServiceRelay.isCancelled(id: request.id) else {
                    FileActionServiceRelay.removeRequest(id: request.id)
                    continue
                }

                let response: FileActionServiceResponse
                do {
                    let result = try await client.perform(
                        action: request.action,
                        requestID: request.id,
                        timeout: .seconds(4)
                    )
                    if FileActionServiceRelay.isCancelled(id: request.id) {
                        response = .init(
                            requestID: request.id,
                            payload: .failure(.internalFailure("中继请求已取消，已阻止返回过期结果。"))
                        )
                    } else {
                        response = .init(
                            requestID: request.id,
                            payload: .actionResult(result)
                        )
                    }
                } catch let error as FileActionServiceClientError {
                    let failure: FileActionServiceFailure
                    if case let .serviceFailure(serviceFailure) = error {
                        failure = serviceFailure
                    } else {
                        failure = .internalFailure(String(describing: error))
                    }
                    response = .init(
                        requestID: request.id,
                        payload: .failure(failure)
                    )
                } catch {
                    response = .init(
                        requestID: request.id,
                        payload: .failure(.internalFailure(error.localizedDescription))
                    )
                }

                do {
                    try FileActionServiceRelay.writeResponse(response, for: request.id)
                    FileActionServiceRelay.removeRequest(id: request.id)
                    FileActionServiceRelay.removeCancellation(id: request.id)
                } catch {
                    // 请求已经进入终态，避免应用重启后无界重试旧动作。
                    FileActionServiceRelay.removeRequest(id: request.id)
                    FileActionServiceRelay.removeCancellation(id: request.id)
                    return
                }
            }
        }
    }

    private func pruneProcessedRequestIDs() {
        let cutoff = Date().addingTimeInterval(-600)
        processedRequestIDs = processedRequestIDs.filter { $0.value >= cutoff }
        if processedRequestIDs.count > 256 {
            let overflow = processedRequestIDs
                .sorted { $0.value < $1.value }
                .prefix(processedRequestIDs.count - 256)
                .map(\.key)
            overflow.forEach { processedRequestIDs.removeValue(forKey: $0) }
        }
    }
}

public final class LiveFileActionServiceConnection: FileActionServiceConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NSXPCConnection
    private var storedInterruptionHandler: (@Sendable () -> Void)?
    private var storedInvalidationHandler: (@Sendable () -> Void)?

    public init(serviceName: String = FileActionServiceXPCInterface.serviceName) {
        connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = FileActionServiceXPCInterface.make()
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
        failure: @escaping @Sendable (any Error) -> Void
    ) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(failure)
            as? FileActionServiceXPCProtocol else {
            failure(FileActionServiceClientError.interrupted)
            return
        }
        proxy.perform(requestData: requestData, reply: reply)
    }

    public func invalidate() {
        connection.invalidate()
    }

    private func emitInterruption() {
        lock.withLock { storedInterruptionHandler }?()
    }

    private func emitInvalidation() {
        lock.withLock { storedInvalidationHandler }?()
    }
}
