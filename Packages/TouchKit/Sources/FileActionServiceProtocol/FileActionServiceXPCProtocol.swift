import Foundation

@objc public protocol FileActionServiceXPCProtocol: NSObjectProtocol {
    func perform(requestData: Data, reply: @escaping (Data) -> Void)
}

public enum FileActionServiceXPCInterface {
    public static let serviceName = "me.touch.launcher.FileActionService"
    public static let allowedSecureCodingClassNames: Set<String> = ["NSData"]

    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: FileActionServiceXPCProtocol.self)
        let dataClasses = NSSet(object: NSData.self) as! Set<AnyHashable>
        interface.setClasses(
            dataClasses,
            for: #selector(FileActionServiceXPCProtocol.perform(requestData:reply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            dataClasses,
            for: #selector(FileActionServiceXPCProtocol.perform(requestData:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        return interface
    }
}
