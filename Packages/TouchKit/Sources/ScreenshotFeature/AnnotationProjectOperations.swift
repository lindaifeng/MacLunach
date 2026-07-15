import Foundation

public enum AnnotationProjectPaths {
    public static func relativePath(documentID: UUID) -> String {
        "Projects/\(documentID.uuidString.lowercased()).touch-annotation.json"
    }
}

public struct AnnotationProjectSaveRequest: Codable, Equatable, Sendable {
    public let document: AnnotationDocument

    public init(document: AnnotationDocument) {
        self.document = document
    }
}

public struct AnnotationProjectSaveResult: Codable, Equatable, Sendable {
    public let relativePath: String

    public init(relativePath: String) {
        self.relativePath = relativePath
    }
}

public struct AnnotationProjectLoadRequest: Codable, Equatable, Sendable {
    public let relativePath: String
    public let fallbackDocument: AnnotationDocument

    public init(relativePath: String, fallbackDocument: AnnotationDocument) {
        self.relativePath = relativePath
        self.fallbackDocument = fallbackDocument
    }
}

public enum AnnotationProjectLoadStatus: String, Codable, Equatable, Sendable {
    case loaded
    case recoveredFromMissingProject
    case recoveredFromCorruptProject
}

public struct AnnotationProjectLoadResult: Codable, Equatable, Sendable {
    public let document: AnnotationDocument
    public let status: AnnotationProjectLoadStatus

    public init(document: AnnotationDocument, status: AnnotationProjectLoadStatus) {
        self.document = document
        self.status = status
    }
}
