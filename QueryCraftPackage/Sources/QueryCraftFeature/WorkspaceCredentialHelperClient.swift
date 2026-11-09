import CryptoKit
import Foundation
import Security

/// The installed v1 helper is deliberately retained across host-app updates.
/// A protocol/security update must use a new installation version explicitly.
struct WorkspaceCredentialHelperClient: Sendable {
    static let helperName = "QueryCraft Credentials.app"
    static let helperIdentifier = "io.github.future0923.QueryCraft.CredentialHelper"
    private static let worker = DispatchQueue(label: "QueryCraft.credentials", qos: .userInitiated)
    let appURL: URL
    let bundledHelperName: String
    let identifier: String
    let protocolVersion: Int

    static func shared(appURL: URL = Bundle.main.bundleURL, installationRoot: URL? = nil) -> Self {
        .init(appURL: appURL, installationRoot: installationRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/QueryCraftCredentials/shared-v2"),
            bundledHelperName: "QueryCraft Shared Credentials.app",
            identifier: "io.github.future0923.QueryCraft.SharedCredentialHelper", protocolVersion: 2)
    }
    let installationRoot: URL

    init(appURL: URL = Bundle.main.bundleURL, installationRoot: URL? = nil,
         bundledHelperName: String = Self.helperName, identifier: String = Self.helperIdentifier,
         protocolVersion: Int = 1) {
        self.bundledHelperName = bundledHelperName
        self.identifier = identifier
        self.protocolVersion = protocolVersion
        self.appURL = appURL
        self.installationRoot = installationRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/QueryCraftCredentials/v1", directoryHint: .isDirectory)
    }

    struct Request: Encodable, Sendable {
        let operation: String
        let account: UUID
        var password: String? = nil
        var allowsInteraction = true
        var vault: String? = nil
    }
    struct Response: Decodable, Sendable {
        let status: OSStatus
        let password: String?
    }

    func send(_ request: Request) async throws -> String? {
        // SecurityAgent can wait for user input. Use a dedicated blocking-I/O queue,
        // not the main actor or Swift's cooperative executor, for the pipe exchange.
        try await withCheckedThrowingContinuation { continuation in
            Self.worker.async {
                do { continuation.resume(returning: try perform(request)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func perform(_ request: Request) throws -> String? {
        let helper = try installedHelper()
        let data = try JSONEncoder().encode(request)
        guard data.count <= 1_048_576 else { throw failure(errSecParam) }
        let process = Process()
        process.executableURL = helper.appending(path: "Contents/MacOS/QueryCraftCredentials")
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // No credential or credential-bearing argument/environment variable is used.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
            let responseData = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw failure(errSecAuthFailed) }
            let response = try JSONDecoder().decode(Response.self, from: responseData)
            guard response.status == errSecSuccess else { throw failure(response.status) }
            return response.password
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    private func installedHelper() throws -> URL {
        let fileManager = FileManager.default
        let trust = try hostTrust()
        // Keep legacy helpers intact: their embedded caller policy only accepts
        // the old certificate. Stable Team-based paths also survive renewal.
        let root = trust.namespace.map { installationRoot.appending(path: $0, directoryHint: .isDirectory) }
            ?? installationRoot
        let installed = root.appending(path: bundledHelperName, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: installed.path) {
            try verify(installed, trust: trust.requirement)
            return installed
        }
        let bundled = appURL.appending(path: "Contents/Helpers/\(bundledHelperName)", directoryHint: .isDirectory)
        try verify(bundled, trust: trust.requirement)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let staged = root.appending(path: ".install-\(UUID().uuidString).app")
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: bundled, to: staged)
        try verify(staged, trust: trust.requirement)
        do { try fileManager.moveItem(at: staged, to: installed) }
        catch {
            // Another QueryCraft process may have installed the same protocol version.
            guard fileManager.fileExists(atPath: installed.path) else { throw error }
        }
        try verify(installed, trust: trust.requirement)
        return installed
    }

    private func hostTrust() throws -> (requirement: String, namespace: String?) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw failure(errSecCSUnsigned) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { throw failure(errSecCSUnsigned) }
        if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String {
            guard team.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) })
            else { throw failure(errSecCSReqFailed) }
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                  let requirement, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
            else { throw failure(errSecCSReqFailed) }
            return (text, "developer-id-\(team)")
        }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        return ("certificate leaf = H\"\(digest)\"", nil)
    }

    private func verify(_ url: URL, trust: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "identifier \"\(identifier)\" and (\(trust))"
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              let bundle = Bundle(url: url), bundle.object(forInfoDictionaryKey: "QCCredentialProtocolVersion") as? Int == protocolVersion
        else { throw failure(errSecCSReqFailed) }
    }

    private func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Credential helper unavailable"
        ])
    }
}
