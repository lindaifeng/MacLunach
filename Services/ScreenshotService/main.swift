import Foundation

let delegate = ScreenshotServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
