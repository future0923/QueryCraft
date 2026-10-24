import Foundation

public enum WorkspaceRequestMethod: String, Codable, CaseIterable, Sendable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

public struct WorkspaceRequest: Equatable, Sendable {
    public let method: WorkspaceRequestMethod
    public let path: String
    public let body: Data?

    public init(
        method: WorkspaceRequestMethod,
        path: String,
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.body = body
    }
}

public struct WorkspaceRequestExecutionResult: Equatable, Sendable {
    public let statusCode: Int
    public let contentType: String?
    public let body: Data

    public init(statusCode: Int, contentType: String?, body: Data) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
    }
}
