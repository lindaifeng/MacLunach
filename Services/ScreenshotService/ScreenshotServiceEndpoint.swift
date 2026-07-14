import Foundation
import ScreenshotFeature
import ScreenshotServiceCore
import ScreenshotServiceProtocol

final class ScreenshotServiceEndpoint: NSObject, ScreenshotXPCProtocol, @unchecked Sendable {
    private final class ReplyBox: @unchecked Sendable {
        let reply: (Data) -> Void
        init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
    }

    private let lock = NSLock()
    private let engine: ScreenCaptureEngine
    private let retentionController: ScreenshotRetentionController?
    private var activeRequestIDs: Set<UUID> = []
    private var captureTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingCancellationRequestIDs: Set<UUID> = []

    override convenience init() {
        let applicationSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport
            .appendingPathComponent("Touch", isDirectory: true)
            .appendingPathComponent("Features", isDirectory: true)
            .appendingPathComponent("me.touch.screenshot", isDirectory: true)
        let retentionController: ScreenshotRetentionController?
        do {
            let store = try ScreenshotHistoryStore(rootURL: root)
            retentionController = ScreenshotRetentionController(rootURL: root, store: store)
        } catch {
            NSLog("ScreenshotService history initialization failed: %@", String(describing: error))
            retentionController = nil
        }
        self.init(
            engine: ScreenCaptureEngine(fileStore: ScreenshotFileStore(rootURL: root)),
            retentionController: retentionController
        )
        if let retentionController {
            Task {
                do {
                    _ = try await retentionController.purgeExpiredTrash(
                        retentionHours: ScreenshotHistoryConfiguration().trashRetentionHours
                    )
                } catch {
                    NSLog("ScreenshotService startup trash cleanup failed: %@", String(describing: error))
                }
            }
        }
    }

    init(
        engine: ScreenCaptureEngine,
        retentionController: ScreenshotRetentionController? = nil
    ) {
        self.engine = engine
        self.retentionController = retentionController
        super.init()
    }

    func perform(requestData: Data, reply: @escaping (Data) -> Void) {
        let request: ScreenshotServiceRequest
        do {
            request = try JSONDecoder().decode(ScreenshotServiceRequest.self, from: requestData)
        } catch {
            let response = ScreenshotServiceResponse(
                requestID: UUID(),
                payload: .failure(.malformedRequest(String(describing: error)))
            )
            reply(encode(response))
            return
        }

        let isAsynchronousAction = (
            request.action.name == "capture"
                || request.action.name == "sampleColor"
        ) && request.action.payload != nil
            || request.action.name == ScreenshotServiceAction.availableContent.name
        guard request.protocolVersion == ScreenshotServiceProtocolVersion.current,
              isAsynchronousAction else {
            _ = lock.withLock { activeRequestIDs.insert(request.id) }
            defer { _ = lock.withLock { activeRequestIDs.remove(request.id) } }
            let processor = ScreenshotServiceRequestProcessor(
                activeRequestCount: { [weak self] in
                    self?.lock.withLock { self?.activeRequestIDs.count ?? 0 } ?? 0
                }
            )
            reply(processor.process(requestData))
            return
        }

        _ = lock.withLock { activeRequestIDs.insert(request.id) }
        let replyBox = ReplyBox(reply)
        let task = Task { [weak self] in
            guard let self else { return }
            let response: ScreenshotServiceResponse
            if request.action.name == "capture" {
                response = await processCapture(request)
            } else if request.action.name == "sampleColor" {
                response = await processColorSample(request)
            } else {
                response = await processAvailableContent(request)
            }
            finishCapture(request.id)
            replyBox.reply(encode(response))
        }
        let shouldKeepTask = lock.withLock { () -> Bool in
            guard activeRequestIDs.contains(request.id) else {
                pendingCancellationRequestIDs.remove(request.id)
                return false
            }
            guard pendingCancellationRequestIDs.remove(request.id) == nil else {
                return false
            }
            captureTasks[request.id] = task
            return true
        }
        if !shouldKeepTask { task.cancel() }
    }

    private func processColorSample(
        _ serviceRequest: ScreenshotServiceRequest
    ) async -> ScreenshotServiceResponse {
        do {
            try Task.checkCancellation()
            guard let payload = serviceRequest.action.payload else {
                return .init(
                    requestID: serviceRequest.id,
                    payload: .failure(.malformedRequest("sampleColor action is missing its payload"))
                )
            }
            let request = try JSONDecoder().decode(ScreenshotColorSampleRequest.self, from: payload)
            let sample = try await engine.sampleColor(request)
            return .init(
                requestID: serviceRequest.id,
                payload: .colorSample(try JSONEncoder().encode(sample))
            )
        } catch is CancellationError {
            return .init(requestID: serviceRequest.id, payload: .failure(.cancelled))
        } catch let error as ScreenshotFeatureError {
            return .init(requestID: serviceRequest.id, payload: .failure(map(error)))
        } catch {
            return .init(
                requestID: serviceRequest.id,
                payload: .failure(.internalFailure(String(describing: error)))
            )
        }
    }

    func cancel(requestID: String) {
        guard let requestID = UUID(uuidString: requestID) else { return }
        let task = lock.withLock { () -> Task<Void, Never>? in
            guard activeRequestIDs.contains(requestID) else { return nil }
            guard let task = captureTasks[requestID] else {
                pendingCancellationRequestIDs.insert(requestID)
                return nil
            }
            return task
        }
        task?.cancel()
    }

    private func processCapture(
        _ serviceRequest: ScreenshotServiceRequest
    ) async -> ScreenshotServiceResponse {
        do {
            try Task.checkCancellation()
            guard let payload = serviceRequest.action.payload else {
                return .init(
                    requestID: serviceRequest.id,
                    payload: .failure(.malformedRequest("capture action is missing its payload"))
                )
            }
            let request = try JSONDecoder().decode(ScreenshotCaptureRequest.self, from: payload)
            let artifact = try await engine.capture(request)
            await recordHistoryIfEnabled(artifact, configuration: request.history)
            let artifactData = try JSONEncoder().encode(artifact)
            return .init(requestID: serviceRequest.id, payload: .capture(artifactData))
        } catch is CancellationError {
            return .init(requestID: serviceRequest.id, payload: .failure(.cancelled))
        } catch let error as ScreenshotFeatureError {
            return .init(requestID: serviceRequest.id, payload: .failure(map(error)))
        } catch {
            return .init(
                requestID: serviceRequest.id,
                payload: .failure(.internalFailure(String(describing: error)))
            )
        }
    }

    private func recordHistoryIfEnabled(
        _ artifact: ScreenshotArtifact,
        configuration: ScreenshotHistoryConfiguration
    ) async {
        // 禁用历史时不能在 XPC 响应前删除捕获文件，否则主进程尚未来得及复制或钉图。
        // keepsFilesWhenDisabled == false 留待客户端完成确认或临时文件 TTL 链路处理。
        guard configuration.isEnabled, let retentionController else { return }
        do {
            try await retentionController.recordCapture(
                artifact,
                configuration: configuration
            )
        } catch {
            // 截图产物已经成功生成；历史故障必须与捕获结果隔离，避免丢失用户截图。
            NSLog("ScreenshotService history update failed: %@", String(describing: error))
        }
    }

    private func processAvailableContent(
        _ serviceRequest: ScreenshotServiceRequest
    ) async -> ScreenshotServiceResponse {
        do {
            try Task.checkCancellation()
            let content = try await engine.availableSelectionContent()
            let contentData = try JSONEncoder().encode(content)
            return .init(
                requestID: serviceRequest.id,
                payload: .availableContent(contentData)
            )
        } catch is CancellationError {
            return .init(requestID: serviceRequest.id, payload: .failure(.cancelled))
        } catch let error as ScreenshotFeatureError {
            return .init(requestID: serviceRequest.id, payload: .failure(map(error)))
        } catch {
            return .init(
                requestID: serviceRequest.id,
                payload: .failure(.internalFailure(String(describing: error)))
            )
        }
    }

    private func finishCapture(_ requestID: UUID) {
        lock.withLock {
            activeRequestIDs.remove(requestID)
            captureTasks.removeValue(forKey: requestID)
            pendingCancellationRequestIDs.remove(requestID)
        }
    }

    private func map(_ error: ScreenshotFeatureError) -> ScreenshotServiceFailure {
        switch error {
        case .permissionDenied:
            .permissionDenied
        case .cancelled:
            .cancelled
        case .noDisplayAvailable:
            .noDisplayAvailable
        case .targetUnavailable:
            .targetUnavailable
        case .encodingFailed:
            .encodingFailed
        case let .storageFailed(message):
            .storageFailed(message)
        default:
            .internalFailure(String(describing: error))
        }
    }

    private func encode(_ response: ScreenshotServiceResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }
}
