import Foundation

protocol LicenseServiceClient: Sendable {
    func startTrial(
        installationID: String,
        deviceName: String
    ) async throws -> SignedLicenseEntitlement
    func activate(
        licenseKey: String,
        installationID: String,
        deviceName: String
    ) async throws -> SignedLicenseEntitlement
    func validate(
        deviceCredential: String,
        installationID: String
    ) async throws -> SignedLicenseEntitlement
    func deactivate(
        deviceCredential: String,
        installationID: String
    ) async throws
}

enum LicenseServiceError: Error, Equatable, Sendable {
    case invalidResponse
    case invalidRequest
    case trialExpired
    case licenseNotFound
    case licenseExpired
    case licenseSuspended
    case activationLimitReached
    case activationMissing
    case serverUnavailable
}

actor HTTPLicenseServiceClient: LicenseServiceClient {
    private struct InstallationRequest: Encodable {
        let installationId: String
        let deviceName: String
    }

    private struct LicenseRequest: Encodable {
        let licenseKey: String
        let installationId: String
        let deviceName: String?
    }

    private struct DeviceCredentialRequest: Encodable {
        let deviceCredential: String
        let installationId: String
    }

    private struct ErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let code: String
        }

        let error: APIError
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func startTrial(
        installationID: String,
        deviceName: String
    ) async throws -> SignedLicenseEntitlement {
        try await post(
            path: "trials/start",
            body: InstallationRequest(
                installationId: installationID,
                deviceName: deviceName
            )
        )
    }

    func activate(
        licenseKey: String,
        installationID: String,
        deviceName: String
    ) async throws -> SignedLicenseEntitlement {
        try await post(
            path: "licenses/activate",
            body: LicenseRequest(
                licenseKey: licenseKey,
                installationId: installationID,
                deviceName: deviceName
            )
        )
    }

    func validate(
        deviceCredential: String,
        installationID: String
    ) async throws -> SignedLicenseEntitlement {
        try await post(
            path: "activations/validate",
            body: DeviceCredentialRequest(
                deviceCredential: deviceCredential,
                installationId: installationID
            )
        )
    }

    func deactivate(
        deviceCredential: String,
        installationID: String
    ) async throws {
        try await postWithoutResponse(
            path: "activations/deactivate",
            body: DeviceCredentialRequest(
                deviceCredential: deviceCredential,
                installationId: installationID
            )
        )
    }

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request
    ) async throws -> Response {
        let data = try await performPost(path: path, body: body)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LicenseServiceError.invalidResponse
        }
    }

    private func postWithoutResponse<Request: Encodable>(
        path: String,
        body: Request
    ) async throws {
        _ = try await performPost(path: path, body: body)
    }

    private func performPost<Request: Encodable>(
        path: String,
        body: Request
    ) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LicenseServiceError.serverUnavailable
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw decodeServiceError(data)
        }
        return data
    }

    private func decodeServiceError(_ data: Data) -> LicenseServiceError {
        guard
            let code = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
                .error.code
        else {
            return .invalidResponse
        }
        switch code {
        case "invalid_request": return .invalidRequest
        case "trial_expired": return .trialExpired
        case "license_not_found": return .licenseNotFound
        case "license_expired": return .licenseExpired
        case "license_suspended": return .licenseSuspended
        case "activation_limit_reached": return .activationLimitReached
        case "activation_not_found": return .activationMissing
        default: return .serverUnavailable
        }
    }
}
