import Foundation
import ScreenshotServiceProtocol

final class ScreenshotServiceEndpoint: NSObject, ScreenshotXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequestIDs: Set<UUID> = []
    private var cancelledRequestIDs: Set<UUID> = []

    func perform(requestData: Data, reply: @escaping (Data) -> Void) {
        let requestID = try? JSONDecoder().decode(
            ScreenshotServiceRequest.self,
            from: requestData
        ).id

        if let requestID {
            lock.withLock { activeRequestIDs.insert(requestID) }
        }
        defer {
            if let requestID {
                lock.withLock {
                    activeRequestIDs.remove(requestID)
                    cancelledRequestIDs.remove(requestID)
                }
            }
        }

        if let requestID, lock.withLock({ cancelledRequestIDs.contains(requestID) }) {
            let response = ScreenshotServiceResponse(
                requestID: requestID,
                payload: .failure(.cancelled)
            )
            reply((try? JSONEncoder().encode(response)) ?? Data())
            return
        }

        let processor = ScreenshotServiceRequestProcessor(
            activeRequestCount: { [weak self] in
                guard let self else { return 0 }
                return lock.withLock { activeRequestIDs.count }
            }
        )
        reply(processor.process(requestData))
    }

    func cancel(requestID: String) {
        guard let requestID = UUID(uuidString: requestID) else { return }
        lock.withLock {
            guard activeRequestIDs.contains(requestID) else { return }
            cancelledRequestIDs.insert(requestID)
        }
    }
}
