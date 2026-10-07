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
    let installationRoot: URL

    init(appURL: URL = Bundle.main.bundleURL, installationRoot: URL? = nil) {
        self.appURL = appURL
        self.installationRoot = installationRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/QueryCraftCredentials/v1", directoryHint: .isDirectory)
    }

    struct Request: Encodable, Sendable {
        let operation: String
        let account: UUID
        var password: String? = nil
        var allowsInteraction = true
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
        let installed = installationRoot.appending(path: Self.helperName, directoryHint: .isDirectory)
        let certificate = try hostCertificate()
        if fileManager.fileExists(atPath: installed.path) {
            try verify(installed, certificate: certificate)
            return installed
        }
        let bundled = appURL.appending(path: "Contents/Helpers/\(Self.helperName)", directoryHint: .isDirectory)
        try verify(bundled, certificate: certificate)
        try fileManager.createDirectory(at: installationRoot, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let staged = installationRoot.appending(path: ".install-\(UUID().uuidString).app")
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: bundled, to: staged)
        try verify(staged, certificate: certificate)
        do { try fileManager.moveItem(at: staged, to: installed) }
        catch {
            // Another QueryCraft process may have installed the same protocol version.
            guard fileManager.fileExists(atPath: installed.path) else { throw error }
        }
        try verify(installed, certificate: certificate)
        return installed
    }

    private func hostCertificate() throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw failure(errSecCSUnsigned) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let certificates = (information as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { throw failure(errSecCSUnsigned) }
        return Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
    }

    private func verify(_ url: URL, certificate: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "identifier \"\(Self.helperIdentifier)\" and certificate leaf = H\"\(certificate)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              let bundle = Bundle(url: url), bundle.object(forInfoDictionaryKey: "QCCredentialProtocolVersion") as? Int == 1
        else { throw failure(errSecCSReqFailed) }
    }

    private func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Credential helper unavailable"
        ])
    }
}
