import Foundation
#if canImport(QueryCraftFeature)
import QueryCraftFeature
#else
import QueryCraftMobileCore
#endif

enum MilvusError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case invalidResponse
    case server(code: Int, message: String)
    case http(status: Int, message: String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Milvus endpoint is invalid."
        case .invalidResponse: "Milvus returned an invalid response."
        case let .server(code, message): "Milvus error \(code): \(message)"
        case let .http(status, message): "Milvus HTTP \(status): \(message)"
        case let .unsupported(message): message
        }
    }
}
