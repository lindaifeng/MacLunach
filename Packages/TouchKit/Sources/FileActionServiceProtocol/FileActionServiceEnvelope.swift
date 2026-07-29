import Foundation

public struct FileActionServiceRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let action: FileActionServiceAction

    public init(
        protocolVersion: Int = FileActionServiceProtocolVersion.current,
        id: UUID = UUID(),
        action: FileActionServiceAction
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.action = action
    }
}

public struct FileActionServiceResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID?
    public let payload: FileActionServiceResponsePayload

    public init(
        protocolVersion: Int = FileActionServiceProtocolVersion.current,
        requestID: UUID?,
        payload: FileActionServiceResponsePayload
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.payload = payload
    }
}

public enum FileActionServiceResponsePayload: Codable, Equatable, Sendable {
    case pong(FileActionServicePong)
    case actionResult(FileActionServiceActionResult)
    case failure(FileActionServiceFailure)
}

public struct FileActionServiceRequestProcessor: Sendable {
    public typealias TimestampProvider = @Sendable () -> Date
    public typealias ActionHandler = @Sendable (
        FileActionServiceAction
    ) -> Result<FileActionServiceActionResult, FileActionServiceFailure>
    public typealias RequestHandler = @Sendable (
        FileActionServiceRequest
    ) -> Result<FileActionServiceActionResult, FileActionServiceFailure>

    private let processID: Int32
    private let now: TimestampProvider
    private let actionHandler: ActionHandler
    private let requestHandler: RequestHandler?

    public init(
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        now: @escaping TimestampProvider = Date.init,
        actionHandler: @escaping ActionHandler = { action in
            .failure(.unsupportedAction(action.name))
        }
    ) {
        self.processID = processID
        self.now = now
        self.actionHandler = actionHandler
        requestHandler = nil
    }

    public init(
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        now: @escaping TimestampProvider = Date.init,
        requestHandler: @escaping RequestHandler
    ) {
        self.processID = processID
        self.now = now
        actionHandler = { action in .failure(.unsupportedAction(action.name)) }
        self.requestHandler = requestHandler
    }

    public func process(_ requestData: Data) -> Data {
        let response: FileActionServiceResponse
        do {
            response = process(try JSONDecoder().decode(FileActionServiceRequest.self, from: requestData))
        } catch {
            response = .init(
                requestID: nil,
                payload: .failure(.malformedRequest(String(describing: error)))
            )
        }
        return (try? JSONEncoder().encode(response)) ?? Data()
    }

    public func process(_ request: FileActionServiceRequest) -> FileActionServiceResponse {
        let payload: FileActionServiceResponsePayload
        if request.protocolVersion != FileActionServiceProtocolVersion.current {
            payload = .failure(.incompatibleProtocol(
                expected: FileActionServiceProtocolVersion.current,
                received: request.protocolVersion
            ))
        } else if request.action == .ping {
            payload = .pong(.init(processID: processID, timestamp: now()))
        } else {
            switch (requestHandler?(request) ?? actionHandler(request.action)) {
            case let .success(result):
                payload = .actionResult(result)
            case let .failure(failure):
                payload = .failure(failure)
            }
        }

        return .init(requestID: request.id, payload: payload)
    }
}
