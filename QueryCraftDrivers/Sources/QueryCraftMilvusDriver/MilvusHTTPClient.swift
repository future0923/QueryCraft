import Foundation
#if canImport(QueryCraftFeature)
import QueryCraftFeature
#else
import QueryCraftMobileCore
#endif

actor MilvusHTTPClient {
    struct Response: Sendable { let body: Data; let statusCode: Int }
    private let baseURL: URL
    private let authentication: DatabaseConnectionAuthentication
    private let database: String?
    private let session: URLSession

    init(configuration: MilvusConnectionConfiguration, protocolClasses: [AnyClass]? = nil) throws {
        guard let baseURL = configuration.baseURL else { throw MilvusError.invalidEndpoint }
        self.baseURL = baseURL
        authentication = configuration.authentication
        database = configuration.database
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.protocolClasses = protocolClasses
        session = URLSession(configuration: sessionConfiguration, delegate: MilvusURLSessionDelegate(tlsMode: configuration.tlsMode), delegateQueue: nil)
    }

    func post(_ path: String, body: Data) async throws -> Response {
        try Task.checkCancellation()
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == baseURL.scheme, url.host == baseURL.host,
              url.port == baseURL.port else { throw MilvusError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let database, !database.isEmpty { request.setValue(database, forHTTPHeaderField: "DB-NAME") }
        switch authentication {
        case let .usernamePassword(username, password):
            request.setValue("Bearer \(username):\(password ?? "")", forHTTPHeaderField: "Authorization")
        case let .apiKey(key):
            if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .none: break
        }
        request.setValue("true", forHTTPHeaderField: "Accept-Type-Allow-Int64")
        request.httpBody = body
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let maximumBytes = 32 * 1024 * 1024
        guard response.expectedContentLength <= maximumBytes else { throw MilvusError.unsupported("Milvus 响应超过 32 MB，请减小分页大小。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw MilvusError.unsupported("Milvus 响应超过 32 MB，请减小分页大小。") }
            data.append(byte)
            if data.count % 65536 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MilvusError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.message(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw MilvusError.http(status: http.statusCode, message: message)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MilvusError.invalidResponse
        }
        guard let code = root["code"] as? Int else { throw MilvusError.invalidResponse }
        if code != 0 {
            throw MilvusError.server(code: code, message: (root["message"] as? String) ?? "Unknown error")
        }
        return Response(body: data, statusCode: http.statusCode)
    }

    func close() { session.invalidateAndCancel() }

    private static func message(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["message"] as? String ?? (root["error"] as? String)
    }
}
