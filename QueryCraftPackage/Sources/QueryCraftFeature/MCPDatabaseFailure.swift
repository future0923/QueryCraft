import Foundation

/// Only structured driver identifiers cross the MCP boundary. Never inspect or
/// return localizedDescription, server messages, SQL text or arbitrary userInfo.
extension MCPFailure {
    enum DatabasePhase: String {
        case driverLoad = "driver_load"
        case connect
        case execution
        case statement
        case queryContext = "query_context"
        case transaction
    }

    static func databaseOperation(_ error: any Error, phase: DatabasePhase, type: DatabaseType) -> MCPFailure {
        let failure = normalized(error)
        var details = failure.details?.objectValue ?? [:]
        // Preserve the most specific phase if an outer execution boundary catches it again.
        if details["phase"] == nil { details["phase"] = .string(phase.rawValue) }
        details["database_type"] = .string(type.rawValue)
        return .init(failure.message, code: failure.code, details: .object(details), recovery: failure.recovery)
    }

    static func databaseFailure(_ error: any Error) -> MCPFailure? {
        if let error = error as? DatabaseDriverError {
            switch error {
            case .notInstalled:
                return .init("The selected database driver is unavailable.", code: .driverUnavailable)
            case .configurationTypeMismatch:
                return .init("The connection configuration does not match the selected driver.", code: .invalidArgument)
            case .unsupportedAuthentication:
                return .init("The selected driver does not support this authentication method.", code: .unsupported)
            }
        }
        let error = error as NSError
        var details: [String: MCPJSONValue] = [:]
        var code: MCPFailureCode = .databaseError
        let state = (error.userInfo["sql_state"] as? String).flatMap { value -> String? in
            value.utf8.count == 5 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) } ? value : nil
        }
        switch error.domain {
        case "io.querycraft.driver.mariadb":
            details["native_code"] = .int(error.code)
            if let state { details["sql_state"] = .string(state) }
            switch error.code {
            case 1049: code = .databaseNotFound
            case 1045, 1698: code = .authenticationFailed
            case 1044, 1142, 1143, 1227, 1370: code = .databaseAccessDenied
            case 2002, 2003, 2005, 2006, 2013, 2055: code = .connectionFailed
            case 2026: code = .tlsFailed
            default: break
            }
        case "io.querycraft.driver.postgresql":
            if let state {
                details["sql_state"] = .string(state)
                switch state {
                case "3D000": code = .databaseNotFound
                case "42501": code = .databaseAccessDenied
                default:
                    if state.hasPrefix("28") { code = .authenticationFailed }
                    else if state.hasPrefix("08") { code = .connectionFailed }
                }
            }
        case "io.querycraft.driver.elasticsearch":
            switch error.code {
            case 401: code = .authenticationFailed
            case 403: code = .databaseAccessDenied
            case -1: code = .connectionFailed
            case -2: code = .tlsFailed
            case -3: code = .timeout
            default: break
            }
            if (100...599).contains(error.code) { details["http_status"] = .int(error.code) }
        case "io.querycraft.driver.redis":
            if error.code != 0 {
                details["native_code"] = .int(error.code)
                if [1, 3, 6].contains(error.code) { code = .connectionFailed }
            }
            // RESP supplies an error token, not SQLSTATE. Export only known tokens.
            if let token = error.userInfo["response_code"] as? String,
               ["NOAUTH", "WRONGPASS", "NOPERM", "WRONGTYPE", "ERR", "OOM", "READONLY", "BUSY", "LOADING", "EXECABORT", "MISCONF", "NOSCRIPT", "CLUSTERDOWN", "MASTERDOWN", "MOVED", "ASK"].contains(token) {
                details["response_code"] = .string(token)
                if ["NOAUTH", "WRONGPASS"].contains(token) { code = .authenticationFailed }
                else if token == "NOPERM" { code = .databaseAccessDenied }
            }
        case "io.querycraft.driver.kafka":
            if error.code != Int.min {
                details["native_code"] = .int(error.code)
                switch error.code {
                case 29, 30, 31, 53: code = .databaseAccessDenied
                case 58: code = .authenticationFailed
                case 13: code = .connectionFailed
                default: break
                }
            }
        case NSURLErrorDomain:
            switch URLError.Code(rawValue: error.code) {
            case .cancelled: return .init("Request was cancelled.", code: .cancelled)
            case .timedOut: code = .timeout
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet: code = .connectionFailed
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired: code = .tlsFailed
            default: return nil
            }
            details["native_code"] = .int(error.code)
        default: return nil
        }
        let message: String
        switch code {
        case .databaseNotFound: message = "The requested database does not exist."
        case .databaseAccessDenied: message = "The database server denied this account permission for the operation."
        case .authenticationFailed: message = "Database server authentication failed."
        case .connectionFailed: message = "The database connection failed or was lost."
        case .tlsFailed: message = "Database TLS negotiation or certificate verification failed."
        case .timeout: message = "The database operation timed out; a write may have completed."
        default: message = details.isEmpty
            ? "The database operation failed. The driver did not retain a classifiable native error code."
            : "The database operation failed. Inspect the safe native diagnostics."
        }
        return .init(message, code: code, details: .object(details))
    }
}
