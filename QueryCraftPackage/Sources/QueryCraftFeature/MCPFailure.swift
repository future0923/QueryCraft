import Foundation
import Security

enum MCPFailureCode: String, Codable, Sendable {
    case invalidArgument = "INVALID_ARGUMENT"
    case policyUnavailable = "POLICY_UNAVAILABLE"
    case accessDenied = "ACCESS_DENIED"
    case connectionNotFound = "CONNECTION_NOT_FOUND"
    case objectNotFound = "OBJECT_NOT_FOUND"
    case sessionUnavailable = "SESSION_UNAVAILABLE"
    case sessionBusy = "SESSION_BUSY"
    case unsupported = "UNSUPPORTED_CAPABILITY"
    case capacity = "CAPACITY_EXCEEDED"
    case confirmationRequired = "CONFIRMATION_REQUIRED"
    case timeout = "OPERATION_TIMEOUT"
    case cancelled = "REQUEST_CANCELLED"
    case driverFailure = "DRIVER_FAILURE"
    case credentialUnavailable = "CREDENTIAL_UNAVAILABLE"
    case credentialDenied = "CREDENTIAL_ACCESS_DENIED"
    case credentialCancelled = "CREDENTIAL_AUTHORIZATION_CANCELLED"
    case resultTooLarge = "RESULT_TOO_LARGE"
    case outcomeUnknown = "OUTCOME_UNKNOWN"
    var recovery: String {
        switch self {
        case .invalidArgument: "Inspect the tool schema and correct the arguments."
        case .policyUnavailable: "Repair and save MCP settings in QueryCraft."
        case .accessDenied: "Use an authorized connection, database and operation. Do not bypass the policy."
        case .connectionNotFound: "Call list_connections and use an exact returned connection_id."
        case .objectNotFound: "Check the selected database and schema, then call list_tables with refresh=true and use an exact returned object name within the authorized scope."
        case .sessionUnavailable: "Close the old session, then open a new session if needed."
        case .sessionBusy: "Wait for the existing operation to finish before calling this session again."
        case .unsupported: "Inspect plugin_tools and the installed driver's capabilities."
        case .capacity: "Close unused sessions or wait for in-flight operations to complete."
        case .confirmationRequired: "Confirm the exact destructive operation before setting confirm_high_risk."
        case .timeout, .cancelled, .outcomeUnknown: "Check the database for the actual outcome before repeating a write or commit. No automatic retry is safe."
        case .driverFailure: "Check the connection, driver and database. Do not automatically retry writes."
        case .credentialUnavailable, .credentialDenied, .credentialCancelled:
            "Open QueryCraft Settings → MCP → Authorize saved credentials. Unlock Keychain if needed; restore missing credentials in the connection editor. Retry only after authorization succeeds."
        case .resultTooLarge: "Narrow the table set, columns or result size. A write may already have completed; do not repeat it to retrieve output."
        }
    }
}
struct MCPFailure: LocalizedError, Sendable {
    let message: String
    let code: MCPFailureCode
    let details: MCPJSONValue?
    let recovery: String?
    init(_ message: String, code: MCPFailureCode = .invalidArgument, details: MCPJSONValue? = nil, recovery: String? = nil) {
        self.message = message; self.code = code; self.details = details; self.recovery = recovery
    }
    var errorDescription: String? { "[\(code.rawValue)] \(message)" }
    var value: MCPJSONValue {
        var error: [String: MCPJSONValue] = ["code": .string(code.rawValue), "message": .string(message),
                                           "recovery": .string(recovery ?? code.recovery), "automatic_retry": false]
        if let details { error["details"] = details }
        return .object(["error": .object(error)])
    }
    static func normalized(_ error: any Error) -> MCPFailure {
        if let failure = error as? MCPFailure { return failure }
        if error is CancellationError { return .init("Request was cancelled.", code: .cancelled) }
        let nsError = error as NSError
        let keychainStatus = (error as? KeychainError)?.status
            ?? (nsError.domain == NSOSStatusErrorDomain ? OSStatus(exactly: nsError.code) : nil)
        if let keychainStatus {
            switch keychainStatus {
            case errSecUserCanceled:
                return .init("Credential authorization was cancelled.", code: .credentialCancelled)
            case errSecAuthFailed, errSecInteractionNotAllowed, errSecInteractionRequired:
                return .init("Keychain access needs authorization in QueryCraft.", code: .credentialDenied)
            default:
                return .init("Saved credentials are unavailable. Check Keychain and the saved connection.", code: .credentialUnavailable)
            }
        }
        // Never return raw driver/Keychain errors, which can contain secrets or SQL values.
        return .init("Database operation failed. Check driver and server availability.", code: .driverFailure)
    }
}
