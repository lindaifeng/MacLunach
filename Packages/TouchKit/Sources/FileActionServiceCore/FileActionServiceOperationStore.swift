import FileActionServiceProtocol
import Foundation

/// 保存文件动作的终态和取消请求。终态会写入受控存储，以便服务重启后同一
/// request ID 可以安全重放；读写失败时会降级为 unknown，绝不假定动作未执行。
public final class FileActionServiceOperationStore: @unchecked Sendable {
    public enum BeginResult: Sendable {
        case execute
        case existing(FileActionServiceOperationState)
    }

    private struct Entry: Codable {
        var status: FileActionServiceOperationStatus
        var updatedAt: Date
        var terminalResult: FileActionServiceTerminalResult?
        var failure: FileActionServiceFailure?
    }

    private struct PersistedEntry: Codable {
        let requestID: UUID
        let entry: Entry
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry]
    private let now: @Sendable () -> Date
    private let storageURL: URL?

    public init(
        storageURL: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.storageURL = storageURL
        self.now = now
        entries = Self.loadEntries(from: storageURL)
        lock.withLock {
            pruneLocked()
            persistLocked()
        }
    }

    public func begin(requestID: UUID) -> BeginResult {
        lock.withLock {
            pruneLocked()
            if let entry = entries[requestID] {
                return .existing(state(requestID: requestID, entry: entry))
            }
            entries[requestID] = .init(
                status: .running,
                updatedAt: now(),
                terminalResult: nil,
                failure: nil
            )
            persistLocked()
            return .execute
        }
    }

    public func state(for requestID: UUID) -> FileActionServiceOperationState {
        lock.withLock {
            guard let entry = entries[requestID] else {
                return .init(requestID: requestID, status: .unknown)
            }
            return state(requestID: requestID, entry: entry)
        }
    }

    public func requestCancellation(for requestID: UUID) -> FileActionServiceOperationState {
        lock.withLock {
            guard var entry = entries[requestID] else {
                return .init(requestID: requestID, status: .unknown)
            }
            switch entry.status {
            case .running:
                entry.status = .cancelling
                entry.updatedAt = now()
                entries[requestID] = entry
                persistLocked()
            case .cancelling, .completed, .failed, .cancelled, .unknown:
                break
            }
            guard let updatedEntry = entries[requestID] else {
                return .init(requestID: requestID, status: .unknown)
            }
            return state(requestID: requestID, entry: updatedEntry)
        }
    }

    public func isCancellationRequested(for requestID: UUID) -> Bool {
        lock.withLock { entries[requestID]?.status == .cancelling }
    }

    public func complete(
        requestID: UUID,
        result: Result<FileActionServiceActionResult, FileActionServiceFailure>
    ) {
        lock.withLock {
            let wasCancelling = entries[requestID]?.status == .cancelling
            let status: FileActionServiceOperationStatus
            if wasCancelling {
                status = .cancelled
            } else {
                switch result {
                case .success: status = .completed
                case .failure: status = .failed
                }
            }
            let terminalPayload: (result: FileActionServiceTerminalResult?, failure: FileActionServiceFailure?)
            switch result {
            case let .success(value):
                terminalPayload = (value.terminalResult, nil)
            case let .failure(error):
                terminalPayload = (nil, error)
            }
            entries[requestID] = .init(
                status: status,
                updatedAt: now(),
                terminalResult: terminalPayload.result,
                failure: terminalPayload.failure
            )
            pruneLocked()
            persistLocked()
        }
    }

    private func state(requestID: UUID, entry: Entry) -> FileActionServiceOperationState {
        .init(
            requestID: requestID,
            status: entry.status,
            terminalResult: entry.terminalResult,
            failure: entry.failure
        )
    }

    private func pruneLocked() {
        let cutoff = now().addingTimeInterval(-600)
        entries = entries.filter { $0.value.updatedAt >= cutoff }
        guard entries.count > 256 else { return }
        let overflow = entries
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(entries.count - 256)
            .map(\.key)
        overflow.forEach { entries.removeValue(forKey: $0) }
    }

    private static func loadEntries(from storageURL: URL?) -> [UUID: Entry] {
        guard let storageURL,
              let data = try? Data(contentsOf: storageURL),
              let persisted = try? JSONDecoder().decode([PersistedEntry].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: persisted.map { ($0.requestID, $0.entry) })
    }

    private func persistLocked() {
        guard let storageURL else { return }
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let persisted = entries.map { PersistedEntry(requestID: $0.key, entry: $0.value) }
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storageURL.path
            )
        } catch {
            // 状态持久化仅用于幂等重放；失败时内存态仍有效，重启后由调用方看到 unknown。
        }
    }
}
