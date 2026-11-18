import CloudKit
import CryptoKit
import Foundation

struct CloudSyncLicenseLink: Sendable, Encodable {
    let installationId: String
    let deviceCredential: String
}

struct CloudSyncAccountSnapshot: Sendable {
    let grants: [CloudSyncGrant]
    let trialExpiresAt: Date?
    let appAccountToken: UUID?
    /// Hosted website checkout for this iCloud account (`checkout` action only).
    let checkoutURL: URL?
    /// Website display prices; present only when the server can take payments.
    let websitePrices: [CloudSyncPlan: String]
    init(grants: [CloudSyncGrant], trialExpiresAt: Date?, appAccountToken: UUID? = nil,
         checkoutURL: URL? = nil, websitePrices: [CloudSyncPlan: String] = [:]) {
        self.grants = grants; self.trialExpiresAt = trialExpiresAt; self.appAccountToken = appAccountToken
        self.checkoutURL = checkoutURL; self.websitePrices = websitePrices
    }
}

enum CloudSyncAccountError: Error, Equatable { case unavailable, identityChanged, invalidResponse, accountConflict }

protocol CloudSyncAccountProviding: Sendable {
    func access(startTrial: Bool, link: CloudSyncLicenseLink?) async throws -> CloudSyncAccountSnapshot
    func preparePurchase() async throws -> CloudSyncAccountSnapshot
    func linkAppStore(_ signedTransactions: [String]) async throws -> CloudSyncAccountSnapshot
    func checkout(_ plan: CloudSyncPlan) async throws -> CloudSyncAccountSnapshot
}
extension CloudSyncAccountProviding {
    func checkout(_ plan: CloudSyncPlan) async throws -> CloudSyncAccountSnapshot { throw CloudSyncAccountError.unavailable }
    func preparePurchase() async throws -> CloudSyncAccountSnapshot { throw CloudSyncAccountError.unavailable }
    func linkAppStore(_ signedTransactions: [String]) async throws -> CloudSyncAccountSnapshot { throw CloudSyncAccountError.unavailable }
}

/// Only signed account-bound responses are accepted. Web auth tokens are
/// single-use, never persisted, and sent in POST bodies rather than URLs.
actor CloudSyncAccountClient: CloudSyncAccountProviding {
    struct Configuration: Sendable {
        let baseURL: URL
        let container: String
        let environment: String
        let apiToken: String
        let publicKey: Data

        static func configured(in bundle: Bundle = .main) -> Self? {
            guard let base = bundle.object(forInfoDictionaryKey: "QCLicenseAPIBaseURL") as? String,
                  let url = URL(string: base), url.scheme == "https",
                  let container = bundle.object(forInfoDictionaryKey: "QCCloudSyncContainer") as? String,
                  container.hasPrefix("iCloud."),
                  let environment = bundle.object(forInfoDictionaryKey: "QCCloudSyncEnvironment") as? String,
                  ["production", "development"].contains(environment),
                  let token = bundle.object(forInfoDictionaryKey: "QCCloudKitAPIToken") as? String, !token.isEmpty,
                  let key = bundle.object(forInfoDictionaryKey: "QCLicensePublicKey") as? String,
                  let data = Data(base64Encoded: key), data.count == 32 else { return nil }
            return Self(baseURL: url, container: container, environment: environment, apiToken: token, publicKey: data)
        }
    }

    private let config: Configuration
    private let container: CKContainer
    private let session: URLSession

    init(configuration: Configuration) {
        config = configuration
        container = CKContainer(identifier: configuration.container)
        let policy = URLSessionConfiguration.ephemeral
        policy.timeoutIntervalForRequest = 25
        policy.timeoutIntervalForResource = 30
        policy.urlCache = nil
        session = URLSession(configuration: policy)
    }

    func access(startTrial: Bool = false, link: CloudSyncLicenseLink? = nil) async throws -> CloudSyncAccountSnapshot {
        try await request(action: link != nil ? "link" : (startTrial ? "trial" : "status"), link: link)
    }

    func preparePurchase() async throws -> CloudSyncAccountSnapshot {
        try await request(action: "purchase", link: nil)
    }

    func linkAppStore(_ signedTransactions: [String]) async throws -> CloudSyncAccountSnapshot {
        guard !signedTransactions.isEmpty, signedTransactions.count <= 8 else { throw CloudSyncAccountError.invalidResponse }
        return try await request(action: "appstore", link: nil, signedTransactions: signedTransactions)
    }

    func checkout(_ plan: CloudSyncPlan) async throws -> CloudSyncAccountSnapshot {
        let snapshot = try await request(action: "checkout", link: nil, plan: plan.serverName)
        guard snapshot.checkoutURL != nil else { throw CloudSyncAccountError.invalidResponse }
        return snapshot
    }

    private func request(action: String, link: CloudSyncLicenseLink?, signedTransactions: [String]? = nil,
                         plan: String? = nil) async throws -> CloudSyncAccountSnapshot {
        let started = ContinuousClock.now
        let user = try await container.userRecordID().recordName
        let account = Self.accountHash(container: config.container, environment: config.environment, user: user)
        let token = try await webToken()
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        struct Request: Encodable {
            let webAuthToken: String
            let nonce: String
            let deviceCredential: String?
            let installationId: String?
            let signedTransactions: [String]?
            let plan: String?
        }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("sync/\(action)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(webAuthToken: token, nonce: nonce,
            deviceCredential: link?.deviceCredential, installationId: link?.installationId, signedTransactions: signedTransactions,
            plan: plan))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudSyncAccountError.invalidResponse }
        if http.statusCode == 409 { throw CloudSyncAccountError.accountConflict }
        guard http.statusCode == 200, data.count <= 64 * 1024 else { throw CloudSyncAccountError.unavailable }
        // An account switch during either network request must not unlock the new account.
        guard try await container.userRecordID().recordName == user else { throw CloudSyncAccountError.identityChanged }
        try Task.checkCancellation()
        let elapsed = started.duration(to: .now)
        guard elapsed < .seconds(120) else { throw CloudSyncAccountError.unavailable }
        return try CloudSyncAccountVerifier.verify(data, publicKey: config.publicKey, account: account,
            nonce: nonce, elapsed: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    static func accountHash(container: String, environment: String, user: String) -> String {
        SHA256.hash(data: Data("\(container)\n\(environment)\n\(user)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func webToken() async throws -> String {
        let operation = CKFetchWebAuthTokenOperation(apiToken: config.apiToken)
        operation.configuration.timeoutIntervalForRequest = 30
        operation.configuration.timeoutIntervalForResource = 60
        let database = container.publicCloudDatabase
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.fetchWebAuthTokenResultBlock = { continuation.resume(with: $0) }
                database.add(operation)
            }
        } onCancel: { operation.cancel() }
    }
}

/// Pure verifier shared by Mac/iOS and deterministic security regression tests.
enum CloudSyncAccountVerifier {
    struct Payload: Codable {
        struct Grant: Codable {
            let source: String
            let plan: String?
            let expiresAt: Int64?
        }
        let version: Int
        let audience: String
        let account: String
        let nonce: String
        let issuedAt: Int64
        let validUntil: Int64
        let trialStartedAt: Int64?
        let trialExpiresAt: Int64?
        let grants: [Grant]
        var appAccountToken: String? = nil
        var checkoutURL: String? = nil
        var websitePrices: [String: String]? = nil
    }

    static func verify(_ data: Data, publicKey: Data, account: String, nonce: String,
                       elapsed: Double = 0, now: Date = .now) throws -> CloudSyncAccountSnapshot {
        struct Envelope: Decodable { let payload: String; let signature: String }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        func decode(_ value: String) -> Data? {
            let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
        }
        guard let payloadData = decode(envelope.payload), let signature = decode(envelope.signature),
              try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(signature, for: payloadData)
        else { throw CloudSyncAccountError.invalidResponse }
        let payload = try JSONDecoder().decode(Payload.self, from: payloadData)
        guard payload.version == 1, payload.audience == "querycraft.cloud-sync", payload.account == account,
              payload.nonce == nonce, payload.issuedAt > 0, payload.validUntil > payload.issuedAt,
              payload.validUntil - payload.issuedAt <= 600, elapsed >= 0, elapsed < 120,
              payload.grants.count <= 100 else { throw CloudSyncAccountError.invalidResponse }
        var grants: [CloudSyncGrant] = []
        for grant in payload.grants {
            let source: CloudSyncGrant.Source
            switch grant.source {
            case "trial": source = .trial
            case "directLicense": source = .directLicense
            case "appStore": source = .appStore
            default: throw CloudSyncAccountError.invalidResponse
            }
            let plan = grant.plan.flatMap { CloudSyncPlan(rawValue: $0 == "half_year" ? "halfYear" : $0) }
            guard (source == .trial && grant.expiresAt != nil && plan == nil)
                || (source != .trial && plan != nil && (grant.expiresAt != nil || plan == .perpetual))
            else { throw CloudSyncAccountError.invalidResponse }
            let deadline = min(grant.expiresAt ?? payload.validUntil, payload.validUntil)
            guard deadline > payload.issuedAt else { continue }
            let remaining = Double(deadline - payload.issuedAt) - elapsed
            if remaining > 0 {
                grants.append(CloudSyncGrant(source: source, plan: plan, expiresAt: now.addingTimeInterval(remaining),
                    purchaseExpiresAt: grant.expiresAt.map { Date(timeIntervalSince1970: Double($0)) }))
            }
        }
        var checkoutURL: URL?
        if let raw = payload.checkoutURL {
            guard let url = websiteCheckoutURL(raw) else { throw CloudSyncAccountError.invalidResponse }
            checkoutURL = url
        }
        // UI uses the original fixed expiry; leases above never outlive it.
        return CloudSyncAccountSnapshot(grants: grants, trialExpiresAt: payload.trialExpiresAt.map { Date(timeIntervalSince1970: Double($0)) },
            appAccountToken: payload.appAccountToken.flatMap(UUID.init(uuidString:)),
            checkoutURL: checkoutURL, websitePrices: websitePrices(payload.websitePrices))
    }

    /// Accept only the provider's hosted pages and Alipay's documented app entry.
    static func websiteCheckoutURL(_ raw: String) -> URL? {
        guard raw.count <= 16_384, let url = URL(string: raw), url.user == nil, url.password == nil,
              url.port == nil, let host = url.host?.lowercased() else { return nil }
        if url.scheme == "https", host == "pay.watcha.cn" || host == "watchapay.com" || host == "alipay.com" || host.hasSuffix(".alipay.com") { return url }
        if url.scheme == "alipays", host == "platformapi", url.path == "/startapp" { return url }
        return nil
    }

    /// Show only plans for which the provider currently offers a purchase link.
    static func websitePrices(_ raw: [String: String]?) -> [CloudSyncPlan: String] {
        guard let raw else { return [:] }
        var prices: [CloudSyncPlan: String] = [:]
        for plan in CloudSyncPlan.allCases {
            guard let value = raw[plan.serverName] else { continue }
            let price = value.trimmingCharacters(in: .whitespaces)
            guard !price.isEmpty, price.count <= 24 else { return [:] }
            prices[plan] = price
        }
        return prices
    }
}
