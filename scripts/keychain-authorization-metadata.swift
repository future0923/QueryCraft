import Foundation
import Security

// Read only this application's access metadata; never request kSecReturnData.
SecKeychainSetUserInteractionAllowed(false)
let service = "io.github.future0923.QueryCraft.connection-profile"
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service, kSecReturnAttributes as String: true,
    kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
var found: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &found)
guard status == errSecSuccess || status == errSecItemNotFound else {
    fputs("Cannot read QueryCraft authorization metadata: \(status)\n", stderr)
    exit(1)
}
var output: [[String: Any]] = []
for row in found as? [[String: Any]] ?? [] {
    guard let account = row[kSecAttrAccount as String] as? String, UUID(uuidString: account) != nil,
          let reference = row[kSecValueRef as String] else { continue }
    let item = reference as! SecKeychainItem
    var access: SecAccess?
    guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { exit(1) }
    var list: CFArray?
    guard SecAccessCopyACLList(access, &list) == errSecSuccess else { exit(1) }
    for acl in list as? [SecACL] ?? [] {
        guard (SecACLCopyAuthorizations(acl) as? [String] ?? []).contains("ACLAuthorizationPartitionID") else { continue }
        var apps: CFArray?
        var description: CFString?
        var selector = SecKeychainPromptSelector(rawValue: 0)
        guard SecACLCopyContents(acl, &apps, &description, &selector) == errSecSuccess,
              let hex = description as String? else { exit(1) }
        var bytes = Data()
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            guard let end = hex.index(cursor, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[cursor..<end], radix: 16) else { exit(1) }
            bytes.append(byte)
            cursor = end
        }
        guard let metadata = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let partitions = metadata["Partitions"] as? [String] else { exit(1) }
        output.append(["account": account, "partitions": partitions])
    }
}
try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
