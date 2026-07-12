import CoreServices
import Foundation

public enum FileIndexEvent: Sendable, Hashable {
    case changed(URL)
    case rescanRequired(URL)
}

public final class FileEventMonitor: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var handler: (@Sendable (FileIndexEvent) -> Void)?

    public init() {}

    deinit { stop() }

    public func start(roots: [URL], handler: @escaping @Sendable (FileIndexEvent) -> Void) {
        stop()
        self.handler = handler
        let paths = roots.map(\.path) as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.handleEvents,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        handler = nil
    }

    public static func coalescedRoots(_ eventPaths: [String]) -> [String] {
        let candidates = Set(eventPaths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path })
        return candidates
            .sorted { $0.count < $1.count || ($0.count == $1.count && $0 < $1) }
            .reduce(into: [String]()) { roots, candidate in
                if !roots.contains(where: { candidate == $0 || candidate.hasPrefix($0 + "/") }) {
                    roots.append(candidate)
                }
            }
            .sorted()
    }

    private static let handleEvents: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let monitor = Unmanaged<FileEventMonitor>.fromOpaque(info).takeUnretainedValue()
        let eventPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let eventFlags = UnsafeBufferPointer(start: flags, count: Int(count))
        for (path, flag) in zip(eventPaths, eventFlags) {
            let url = URL(fileURLWithPath: path)
            let requiresRescan = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
                || flag & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
            monitor.handler?(requiresRescan ? .rescanRequired(url) : .changed(url))
        }
    }
}
