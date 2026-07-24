import FileActionServiceProtocol
import Foundation

/// 在未沙盒化的 XPC 服务中执行文件系统和外部应用动作。
/// FinderExtension 只负责读取 Finder 上下文和展示菜单，避免直接写入用户目录时
/// 被扩展沙盒拒绝。
private struct FileActionServiceExecutor: Sendable {
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

    func perform(
        _ action: FileActionServiceAction
    ) -> Result<FileActionServiceActionResult, FileActionServiceFailure> {
        switch action.name {
        case "createFile":
            return createFile(action)
        case "createFolder":
            return createFolder(action)
        case "openTerminal":
            return openTerminal(action)
        default:
            return .failure(.unsupportedAction(action.name))
        }
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
        let bundleIdentifiers = ([preferred] + Self.terminalBundleIdentifiers)
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
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
        let executor = FileActionServiceExecutor()
        processor = FileActionServiceRequestProcessor(actionHandler: executor.perform)
        super.init()
    }

    func perform(requestData: Data, reply: @escaping (Data) -> Void) {
        reply(processor.process(requestData))
    }
}
