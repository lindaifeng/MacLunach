import FileActionServiceProtocol
import Foundation

final class FileActionServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = FileActionServiceXPCInterface.make()
        newConnection.exportedObject = FileActionServiceEndpoint()
        newConnection.resume()
        return true
    }
}
