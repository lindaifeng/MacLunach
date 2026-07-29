import FileActionServiceCore
import FileActionServiceProtocol
import Foundation

/// 在未沙盒化的 XPC 服务中执行文件系统和外部应用动作。
/// FinderExtension 只负责读取 Finder 上下文和展示菜单，避免直接写入用户目录时
/// 被扩展沙盒拒绝。
private final class FileActionServiceExecutor: @unchecked Sendable {
    private let moveExecutor = FileActionServiceMoveExecutor()
    private let operationStore: FileActionServiceOperationStore
    private static let defaultTerminalBundleIdentifier = "com.apple.Terminal"
    private static let terminalBundleIdentifiers = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "net.kovidgoyal.kitty"
    ]

    init(operationStore: FileActionServiceOperationStore = .init()) {
        self.operationStore = operationStore
    }

    func perform(
        _ request: FileActionServiceRequest
    ) -> Result<FileActionServiceActionResult, FileActionServiceFailure> {
        let action = request.action
        switch action.name {
        case "operationStatus":
            guard let operationRequestID = action.operationRequestID else {
                return .failure(.malformedRequest("状态查询缺少请求 ID"))
            }
            return .success(.init(operationState: operationStore.state(for: operationRequestID)))
        case "cancelOperation":
            guard let operationRequestID = action.operationRequestID else {
                return .failure(.malformedRequest("取消请求缺少请求 ID"))
            }
            return .success(.init(
                operationState: operationStore.requestCancellation(for: operationRequestID)
            ))
        default:
            break
        }

        switch operationStore.begin(requestID: request.id) {
        case .execute:
            break
        case let .existing(state):
            if let terminalResult = state.terminalResult {
                return .success(.init(terminalResult: terminalResult))
            }
            if let failure = state.failure {
                return .failure(failure)
            }
            return .success(.init(operationState: state))
        }

        let result: Result<FileActionServiceActionResult, FileActionServiceFailure>
        switch action.name {
        case "createFile":
            result = createFile(action)
        case "createFolder":
            result = createFolder(action)
        case "openTerminal":
            result = openTerminal(action)
        case "move":
            result = moveExecutor.perform(action) { [operationStore] in
                operationStore.isCancellationRequested(for: request.id)
            }
        default:
            result = .failure(.unsupportedAction(action.name))
        }
        operationStore.complete(requestID: request.id, result: result)
        return result
    }

    private func createFile(
        _ action: FileActionServiceAction
    ) -> Result<FileActionServiceActionResult, FileActionServiceFailure> {
        guard let directory = validatedDirectory(from: action.directory) else {
            return .failure(.internalFailure("目标位置不是有效文件夹"))
        }

        let fileExtension = normalizeExtension(action.fileExtension ?? "")
        let data = Data((action.initialContent ?? "").utf8)
        for index in 1...10_000 {
            let baseName = index == 1 ? "未命名" : "未命名 \(index)"
            let name = fileExtension.isEmpty ? baseName : "\(baseName).\(fileExtension)"
            let destination = directory.appendingPathComponent(name, isDirectory: false)
            do {
                try data.write(to: destination, options: .withoutOverwriting)
                return .success(.init(createdURL: destination))
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                return .failure(.internalFailure(error.localizedDescription))
            }
        }
        return .failure(.internalFailure("无法找到可用的文件名"))
    }

    private func createFolder(
        _ action: FileActionServiceAction
    ) -> Result<FileActionServiceActionResult, FileActionServiceFailure> {
        guard let directory = validatedDirectory(from: action.directory) else {
            return .failure(.internalFailure("目标位置不是有效文件夹"))
        }

        for index in 1...10_000 {
            let name = index == 1 ? "未命名文件夹" : "未命名文件夹 \(index)"
            let destination = directory.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
                return .success(.init(createdURL: destination))
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                return .failure(.internalFailure(error.localizedDescription))
            }
        }
        return .failure(.internalFailure("无法找到可用的文件夹名称"))
    }

    private func openTerminal(
        _ action: FileActionServiceAction
    ) -> Result<FileActionServiceActionResult, FileActionServiceFailure> {
        guard let directory = validatedDirectory(from: action.directory) else {
            return .failure(.internalFailure("工作目录不是有效文件夹"))
        }

        let preferred = action.preferredBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleIdentifiers: [String]
        if Self.terminalBundleIdentifiers.contains(preferred) {
            bundleIdentifiers = [preferred] + Self.terminalBundleIdentifiers.filter { $0 != preferred }
        } else {
            bundleIdentifiers = Self.terminalBundleIdentifiers
        }

        for bundleIdentifier in bundleIdentifiers {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-b", bundleIdentifier, directory.path]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return .success(.init(openedApplicationBundleIdentifier: bundleIdentifier))
                }
            } catch {
                continue
            }
        }

        return .failure(.internalFailure("没有找到可用的终端应用"))
    }

    private func validatedDirectory(from url: URL?) -> URL? {
        guard let url else { return nil }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url.standardizedFileURL
    }

    private func normalizeExtension(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

final class FileActionServiceEndpoint: NSObject, FileActionServiceXPCProtocol {
    private let processor: FileActionServiceRequestProcessor

    override init() {
        let executor = FileActionServiceExecutor(
            operationStore: .init(storageURL: Self.operationStoreURL())
        )
        processor = FileActionServiceRequestProcessor(requestHandler: executor.perform)
        super.init()
    }

    private static func operationStoreURL() -> URL? {
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = applicationSupport
                .appendingPathComponent("一念", isDirectory: true)
                .appendingPathComponent("FileActionService", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return directory.appendingPathComponent("operation-states.json", isDirectory: false)
        } catch {
            NSLog("FileActionService 操作状态持久化不可用：%@", String(describing: error))
            return nil
        }
    }

    func perform(requestData: Data, reply: @escaping (Data) -> Void) {
        reply(processor.process(requestData))
    }
}
