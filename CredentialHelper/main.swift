import Foundation
import Security
import Darwin

// Replaced with the existing pinned public certificate fingerprint at packaging time.
let certificate = "__PINNED_CERTIFICATE_SHA1__"
#if SHARED_CREDENTIALS
let service = "io.github.future0923.QueryCraft.shared-connection-profile-v2"
let callerRequirement = "certificate leaf = H\"\(certificate)\" and (identifier \"io.github.future0923.QueryCraft\" or identifier \"io.github.future0923.QueryCraft.Dev\" or identifier \"io.github.future0923.QueryCraft.MCP\" or identifier \"io.github.future0923.QueryCraft.MCP.Dev\")"
#else
let service = "io.github.future0923.QueryCraft.connection-profile"
let callerRequirement = "certificate leaf = H\"\(certificate)\" and (identifier \"io.github.future0923.QueryCraft\" or identifier \"io.github.future0923.QueryCraft.Dev\")"
#endif

struct Request: Decodable {
    let operation: String
    let account: UUID
    let password: String?
    let allowsInteraction: Bool
    var vault: String? = nil
}
struct Response: Encodable {
    let status: OSStatus
    var password: String? = nil
}

func authorizedCaller(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(callerRequirement as CFString, [], &requirement) == errSecSuccess,
          let requirement else { return false }
    var caller: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &caller) == errSecSuccess,
          let caller else { return false }
    return SecCodeCheckValidity(caller, [], requirement) == errSecSuccess
}

#if SHARED_CREDENTIALS
func executeShared(_ request: Request) -> Response {
    // Every password in this data directory belongs to ONE Keychain item/ACL.
    // Only the requested account leaves the authenticated helper process.
    guard let vault = request.vault, vault.count == 64,
          vault.allSatisfy({ $0.isHexDigit }) else { return Response(status: errSecParam) }
    let lockURL = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "vault.lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return Response(status: errSecIO) }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { return Response(status: errSecIO) }
    defer { flock(descriptor, LOCK_UN) }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: "connections-" + vault]
    var read = query
    read[kSecReturnData as String] = true
    read[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(read as CFDictionary, &value)
    guard status == errSecSuccess || status == errSecItemNotFound else { return Response(status: status) }
    var passwords: [String: String] = [:]
    if status == errSecSuccess {
        guard let data = value as? Data, data.count <= 16_777_216,
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return Response(status: errSecDecode) }
        passwords = decoded
    }
    let account = request.account.uuidString
    switch request.operation {
    case "get": return Response(status: errSecSuccess, password: passwords[account])
    case "import":
        guard let password = request.password else { return Response(status: errSecParam) }
        if passwords[account] != nil { return Response(status: errSecSuccess) }
        passwords[account] = password
    case "save":
        guard let password = request.password else { return Response(status: errSecParam) }
        passwords[account] = password
    case "clear":
        // Unmigrated legacy items still need their owner's permission to delete.
        // Fail closed instead of leaving an undisclosed credential behind or prompting.
        SecKeychainSetUserInteractionAllowed(false)
        let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.future0923.QueryCraft.connection-profile",
            kSecAttrAccount as String: account]
        let deleted = SecItemDelete(legacy as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { return Response(status: deleted) }
        SecKeychainSetUserInteractionAllowed(request.allowsInteraction)
        passwords[account] = "{}" // Do not let an in-flight legacy import resurrect a cleared password.
    case "delete": passwords.removeValue(forKey: account)
    default: return Response(status: errSecParam)
    }
    if passwords.isEmpty {
        let deleted = SecItemDelete(query as CFDictionary)
        return Response(status: deleted == errSecItemNotFound ? errSecSuccess : deleted)
    }
    guard let data = try? JSONEncoder().encode(passwords), data.count <= 16_777_216 else { return Response(status: errSecParam) }
    var written = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if written == errSecItemNotFound {
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrLabel as String] = "QueryCraft connection passwords"
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        written = SecItemAdd(insert as CFDictionary, nil)
    }
    return Response(status: written)
}
#endif

func execute(_ request: Request) -> Response {
    SecKeychainSetUserInteractionAllowed(request.allowsInteraction)
    #if SHARED_CREDENTIALS
    return executeShared(request)
    #else
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: request.account.uuidString,
    ]
    switch request.operation {
    case "get":
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &value)
        if status == errSecItemNotFound { return Response(status: errSecSuccess) }
        guard status == errSecSuccess else { return Response(status: status) }
        guard let data = value as? Data, let password = String(data: data, encoding: .utf8) else {
            return Response(status: errSecDecode)
        }
        return Response(status: errSecSuccess, password: password)
    case "save":
        guard let password = request.password else { return Response(status: errSecParam) }
        let data = Data(password.utf8)
        // Updating in place preserves existing authorization and avoids deleting a
        // working password when an insert fails.
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        return Response(status: status)
    case "delete":
        let status = SecItemDelete(query as CFDictionary)
        return Response(status: status == errSecItemNotFound ? errSecSuccess : status)
    default:
        return Response(status: errSecParam)
    }
    #endif
}

// This is a private pipe protocol, not a general-purpose password CLI. Authenticate
// the live parent before reading input and again before returning any secret.
let parentPID = getppid()
guard authorizedCaller(parentPID) else { exit(77) }
do {
    let data = try FileHandle.standardInput.read(upToCount: 1_048_577) ?? Data()
    guard data.count <= 1_048_576 else { exit(65) }
    // read(upToCount:) may return a partial pipe read; collect the rest to EOF.
    var complete = data
    while let next = try FileHandle.standardInput.read(upToCount: 65_536), !next.isEmpty {
        complete.append(next)
        guard complete.count <= 1_048_576 else { exit(65) }
    }
    let request = try JSONDecoder().decode(Request.self, from: complete)
    let response = execute(request)
    guard getppid() == parentPID, authorizedCaller(parentPID) else { exit(77) }
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response))
} catch {
    // Never log request payloads, passwords, or decoding diagnostics.
    exit(65)
}
