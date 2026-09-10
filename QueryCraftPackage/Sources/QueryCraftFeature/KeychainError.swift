import Foundation
import Security

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            AppCopy.current.text("钥匙串错误：\(message)", "Keychain error: \(message)")
        } else {
            AppCopy.current.text(
                "钥匙串错误（\(status)）。",
                "Keychain error (\(status))."
            )
        }
    }
}
