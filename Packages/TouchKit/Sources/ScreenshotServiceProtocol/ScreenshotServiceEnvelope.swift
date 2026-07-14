import Foundation

public struct ScreenshotServiceRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let action: ScreenshotServiceAction

    public init(
        protocolVersion: Int = ScreenshotServiceProtocolVersion.current,
        id: UUID = UUID(),
        action: ScreenshotServiceAction
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.action = action
    }
}

public struct ScreenshotServiceResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let payload: ScreenshotServiceResponsePayload

    public init(
        protocolVersion: Int = ScreenshotServiceProtocolVersion.current,
        requestID: UUID,
        payload: ScreenshotServiceResponsePayload
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.payload = payload
    }
}

public enum ScreenshotServiceResponsePayload: Codable, Equatable, Sendable {
    case pong(ScreenshotPong)
    case health(ScreenshotServiceHealth)
    case availableContent(Data)
    case capture(Data)
    case colorSample(Data)
    case recognition(Data)
    case artifactExport(Data)
    case artifactDeleted
    case failure(ScreenshotServiceFailure)
}

public struct ScreenshotServiceRequestProcessor: Sendable {
    public typealias ActiveRequestCount = @Sendable () -> Int

    private let processID: Int32
    private let activeRequestCount: ActiveRequestCount

    public init(
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        activeRequestCount: @escaping ActiveRequestCount = { 0 }
    ) {
        self.processID = processID
        self.activeRequestCount = activeRequestCount
    }

    public func process(_ requestData: Data) -> Data {
        let response: ScreenshotServiceResponse
        do {
            let request = try JSONDecoder().decode(ScreenshotServiceRequest.self, from: requestData)
            response = process(request)
        } catch {
            response = ScreenshotServiceResponse(
                requestID: UUID(),
                payload: .failure(.malformedRequest(String(describing: error)))
            )
        }

        // Every response model in this module is JSON-encodable by construction.
        // Keeping this API non-throwing prevents malformed client input from taking down the XPC service.
        return (try? JSONEncoder().encode(response)) ?? Data()
    }

    public func process(_ request: ScreenshotServiceRequest) -> ScreenshotServiceResponse {
        let payload: ScreenshotServiceResponsePayload
        if request.protocolVersion != ScreenshotServiceProtocolVersion.current {
            payload = .failure(.incompatibleProtocol(
                expected: ScreenshotServiceProtocolVersion.current,
                received: request.protocolVersion
            ))
        } else {
            switch request.action {
            case .ping:
                payload = .pong(.init(processID: processID))
            case .health:
                payload = .health(.init(
                    processID: processID,
                    activeRequestCount: activeRequestCount()
                ))
            default:
                payload = .failure(.unsupportedAction(request.action.name))
            }
        }

        return ScreenshotServiceResponse(requestID: request.id, payload: payload)
    }
}
