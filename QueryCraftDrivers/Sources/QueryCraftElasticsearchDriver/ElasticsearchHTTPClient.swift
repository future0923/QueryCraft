import Foundation
import OSLog
import QueryCraftFeature

actor ElasticsearchHTTPClient {
    private static let logger = Logger(
        subsystem: "io.github.future0923.QueryCraft",
        category: "ElasticsearchDriver"
    )
    struct Response: Sendable {
        let statusCode: Int
        let contentType: String?
        let headers: [String: String]
        let body: Data
    }

    private let configuration: ElasticsearchConnectionConfiguration
    private let sessionDelegate: ElasticsearchURLSessionDelegate
    private let session: URLSession

    init(
        configuration: ElasticsearchConnectionConfiguration,
        protocolClasses: [AnyClass]? = nil
    ) throws {
        guard configuration.baseURL != nil else {
            throw ElasticsearchError.invalidEndpoint
        }
        self.configuration = configuration
        let sessionDelegate = ElasticsearchURLSessionDelegate(
            tlsMode: configuration.tlsMode
        )
        self.sessionDelegate = sessionDelegate
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses {
            sessionConfiguration.protocolClasses = protocolClasses
        }
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
    }

    func perform(
        method: WorkspaceRequestMethod,
        path: String,
        body: Data? = nil,
        maximumResponseBytes: Int = 16 * 1_024 * 1_024,
        enforceReadOnlyPolicy: Bool = false,
        preserveCompletedResponse: Bool = false,
        acceptsHTTPError: Bool = false
    ) async throws -> Response {
        try Task.checkCancellation()
        if enforceReadOnlyPolicy {
            try ElasticsearchReadOnlyRequestPolicy.validate(
                WorkspaceRequest(method: method, path: path, body: body)
            )
        } else {
            try ElasticsearchReadOnlyRequestPolicy.validateRelativePath(path)
        }
        var transportMethod = method
        if method == .get, body?.isEmpty == false {
            let original = WorkspaceRequest(method: method, path: path, body: body)
            try WorkspaceReadOnlyRequestValidator.validate(original)
            try ElasticsearchReadOnlyRequestPolicy.validate(original)
            transportMethod = .post
            try ElasticsearchReadOnlyRequestPolicy.validate(
                WorkspaceRequest(method: transportMethod, path: path, body: body)
            )
        }
        guard let baseURL = configuration.baseURL,
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == baseURL.scheme,
              url.host == baseURL.host,
              url.port == baseURL.port
        else {
            throw ElasticsearchError.invalidRelativePath
        }

        var request = URLRequest(url: url)
        request.httpMethod = transportMethod.rawValue
        request.httpBody = method == .get && body?.isEmpty == true ? nil : body
        if WorkspaceRequestClassifier.isNDJSON(path: path), let body = request.httpBody, !body.isEmpty, body.last != 10 {
            request.httpBody = body + Data([10])
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            let contentType = WorkspaceRequestClassifier.isNDJSON(path: path)
                ? "application/x-ndjson"
                : "application/json"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        switch configuration.authentication {
        case .usernamePassword(let username, let password):
            let value = Data("\(username):\(password ?? "")".utf8)
                .base64EncodedString()
            request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
        case .apiKey(let key):
            if let key, !key.isEmpty {
                request.setValue("ApiKey \(key)", forHTTPHeaderField: "Authorization")
            }
        case .none:
            break
        }

        let data: Data
        let response: URLResponse
        do {
            let (bytes, receivedResponse) = try await session.bytes(for: request)
            // AsyncBytes leaves its request active when consumption stops early.
            defer { bytes.task.cancel() }
            response = receivedResponse
            if method != .head,
               response.expectedContentLength > Int64(maximumResponseBytes) {
                throw ElasticsearchError.responseTooLarge(maximumResponseBytes)
            }
            data = try await Self.readBody(from: bytes, maximumByteCount: maximumResponseBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }
            throw ElasticsearchError.from(error)
        }
        return try Self.completedResponse(
            data: data, response: response,
            maximumResponseBytes: maximumResponseBytes,
            preserveCompletedResponse: preserveCompletedResponse,
            acceptsHTTPError: acceptsHTTPError
        )
    }

    nonisolated static func readBody<Bytes: AsyncSequence & Sendable>(
        from bytes: Bytes, maximumByteCount: Int
    ) async throws -> Data where Bytes.Element == UInt8 {
        try Task.checkCancellation()
        guard maximumByteCount >= 0 else {
            throw ElasticsearchError.responseTooLarge(maximumByteCount)
        }
        // Match the existing download pipeline's bounded chunking. This keeps
        // cancellation/fairness checks off the per-byte hot path.
        let chunkSize = 64 * 1_024
        var body = Data()
        body.reserveCapacity(min(maximumByteCount, chunkSize))
        var chunk = [UInt8]()
        chunk.reserveCapacity(min(maximumByteCount, chunkSize))
        for try await byte in bytes {
            guard body.count + chunk.count < maximumByteCount else {
                throw ElasticsearchError.responseTooLarge(maximumByteCount)
            }
            chunk.append(byte)
            if chunk.count == chunkSize {
                body.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        body.append(contentsOf: chunk)
        return body
    }

    nonisolated static func completedResponse(
        data: Data,
        response: URLResponse,
        maximumResponseBytes: Int,
        preserveCompletedResponse: Bool,
        acceptsHTTPError: Bool = false
    ) throws -> Response {
        // A received write acknowledgement must not become an uncertain outcome
        // just because cancellation arrived while the caller resumed.
        if !preserveCompletedResponse { try Task.checkCancellation() }
        guard let http = response as? HTTPURLResponse else {
            throw ElasticsearchError.invalidResponse
        }
        guard data.count <= maximumResponseBytes else {
            throw ElasticsearchError.responseTooLarge(maximumResponseBytes)
        }
        let headers: [String: String] = Dictionary(
            uniqueKeysWithValues: http.allHeaderFields.compactMap {
            guard let key = $0.key as? String else { return nil }
            return (key.lowercased(), String(describing: $0.value))
            }
        )
        if !acceptsHTTPError, !(200..<300).contains(http.statusCode) {
            let error = parseError(status: http.statusCode, data: data)
            Self.logger.error(
                "Elasticsearch request failed with HTTP \(http.statusCode, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        return Response(
            statusCode: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            headers: headers,
            body: data
        )
    }

    func close() {
        session.invalidateAndCancel()
    }

    private nonisolated static func parseError(status: Int, data: Data) -> ElasticsearchError {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 429: return .rateLimited
        default:
            if status == 404,
               Self.errorType(in: data) == "resource_not_found_exception",
               Self.errorMessage(in: data)?.localizedCaseInsensitiveContains(
                   "point in time"
               ) == true
            {
                return .pitExpired
            }
            let message = Self.errorMessage(in: data)
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            return .server(status: status, message: message)
        }
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"]
        else { return nil }
        if let message = error as? String { return message }
        guard let object = error as? [String: Any] else { return nil }
        return (object["root_cause"] as? [[String: Any]])?.first?["reason"] as? String
            ?? object["reason"] as? String
            ?? object["type"] as? String
    }

    private static func errorType(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let object = root["error"] as? [String: Any]
        else { return nil }
        return object["type"] as? String
    }
}
