import Foundation
import Security
import Darwin

// Replaced with the existing pinned public certificate fingerprint at packaging time.
let certificate = "__PINNED_CERTIFICATE_SHA1__"
let service = "io.github.future0923.QueryCraft.connection-profile"
let callerRequirement = "certificate leaf = H\"\(certificate)\" and (identifier \"io.github.future0923.QueryCraft\" or identifier \"io.github.future0923.QueryCraft.Dev\")"

struct Request: Decodable {
    let operation: String
    let account: UUID
    let password: String?
    let allowsInteraction: Bool
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

func execute(_ request: Request) -> Response {
    SecKeychainSetUserInteractionAllowed(request.allowsInteraction)
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
