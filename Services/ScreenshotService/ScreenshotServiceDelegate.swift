import Foundation
import ScreenshotServiceProtocol

final class ScreenshotServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = ScreenshotXPCInterface.make()
        newConnection.exportedObject = ScreenshotServiceEndpoint()
        newConnection.resume()
        return true
    }
}
