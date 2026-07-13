import Foundation

@objc public protocol ScreenshotXPCProtocol: NSObjectProtocol {
    func perform(requestData: Data, reply: @escaping (Data) -> Void)
    func cancel(requestID: String)
}

public enum ScreenshotXPCInterface {
    public static let serviceName = "me.touch.launcher.ScreenshotService"

    /// Data envelopes and string request IDs are the only objects crossing the XPC boundary.
    public static let allowedSecureCodingClassNames: Set<String> = ["NSData", "NSString"]

    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: ScreenshotXPCProtocol.self)
        let dataClasses = NSSet(object: NSData.self) as! Set<AnyHashable>
        let stringClasses = NSSet(object: NSString.self) as! Set<AnyHashable>
        interface.setClasses(
            dataClasses,
            for: #selector(ScreenshotXPCProtocol.perform(requestData:reply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            dataClasses,
            for: #selector(ScreenshotXPCProtocol.perform(requestData:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            stringClasses,
            for: #selector(ScreenshotXPCProtocol.cancel(requestID:)),
            argumentIndex: 0,
            ofReply: false
        )
        return interface
    }
}
