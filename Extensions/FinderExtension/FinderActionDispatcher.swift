import FileActionServiceProtocol
import Foundation
import SuperRightFeature

final class FinderActionDispatcher: Sendable {
    private let client: FileActionServiceClient

    init(client: FileActionServiceClient = FileActionServiceClient()) {
        self.client = client
    }

    func ping() async -> Result<FileActionServicePong, FileActionServiceClientError> {
        do {
            return .success(try await client.ping(timeout: .seconds(1)))
        } catch let error as FileActionServiceClientError {
            return .failure(error)
        } catch {
            return .failure(.interrupted)
        }
    }

    func createFile(
        in directory: URL,
        format: NewFileFormatDefinition
    ) async -> Result<URL, FileActionServiceClientError> {
        do {
            let result = try await FileActionServiceRelay.perform(action: .createFile(
                directory: directory,
                displayName: format.displayName,
                fileExtension: format.fileExtension,
                initialContent: format.initialContent
            ))
            guard let url = result.createdURL else {
                throw FileActionServiceClientError.unexpectedPayload
            }
            return .success(url)
        } catch let error as FileActionServiceClientError {
            return .failure(error)
        } catch {
            return .failure(.interrupted)
        }
    }

    func createFolder(
        in directory: URL
    ) async -> Result<URL, FileActionServiceClientError> {
        do {
            let result = try await FileActionServiceRelay.perform(
                action: .createFolder(directory: directory)
            )
            guard let url = result.createdURL else {
                throw FileActionServiceClientError.unexpectedPayload
            }
            return .success(url)
        } catch let error as FileActionServiceClientError {
            return .failure(error)
        } catch {
            return .failure(.interrupted)
        }
    }

    func openTerminal(
        at directory: URL,
        preferredBundleIdentifier: String
    ) async -> Result<String, FileActionServiceClientError> {
        do {
            let result = try await FileActionServiceRelay.perform(action: .openTerminal(
                directory: directory,
                preferredBundleIdentifier: preferredBundleIdentifier
            ))
            guard let bundleIdentifier = result.openedApplicationBundleIdentifier else {
                throw FileActionServiceClientError.unexpectedPayload
            }
            return .success(bundleIdentifier)
        } catch let error as FileActionServiceClientError {
            return .failure(error)
        } catch {
            return .failure(.interrupted)
        }
    }

    func move(
        sources: [URL],
        destination: URL,
        conflictPolicy: FileActionServiceMoveConflictPolicy
    ) async -> Result<FileActionServiceMoveResult, FileActionServiceClientError> {
        do {
            let result = try await FileActionServiceRelay.perform(action: .move(
                sources: sources,
                destination: destination,
                conflictPolicy: conflictPolicy
            ))
            guard let move = result.move else {
                throw FileActionServiceClientError.unexpectedPayload
            }
            return .success(move)
        } catch let error as FileActionServiceClientError {
            return .failure(error)
        } catch {
            return .failure(.interrupted)
        }
    }
}
