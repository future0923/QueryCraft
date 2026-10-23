import Foundation
import Observation
import QueryCraftMobileCore
import QueryCraftMobileTransport

struct MobileConnectionProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var database: String
    var tlsMode: ConnectionTLSMode
    var remembersPassword: Bool
    var requiresPassword: Bool

    func configuration(password: String?, database: String? = nil) -> MariaDBTransportConfiguration {
        .init(host: host, port: port, username: username, password: password,
              database: database ?? (self.database.isEmpty ? nil : self.database), tlsMode: tlsMode)
    }
}

@MainActor @Observable
final class MobileConnectionDraft: Identifiable {
    let id: UUID
    var name: String
    var host: String
    var port: String
    var username: String
    var password: String
    var database: String
    var tlsMode: ConnectionTLSMode
    var remembersPassword: Bool
    var message: String?
    var isTesting = false

    init(profile: MobileConnectionProfile? = nil, password: String = "") {
        id = profile?.id ?? UUID()
        name = profile?.name ?? ""
        host = profile?.host ?? "127.0.0.1"
        port = profile.map { String($0.port) } ?? "3306"
        username = profile?.username ?? "root"
        self.password = password
        database = profile?.database ?? ""
        tlsMode = profile?.tlsMode ?? .required
        remembersPassword = profile?.remembersPassword ?? false
    }

    func profile() throws -> MobileConnectionProfile {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !host.isEmpty, !username.isEmpty,
              let port = Int(port), (1...65535).contains(port), !host.contains("\0"),
              !database.contains("\0"), tlsMode == .disabled || tlsMode == .required else {
            throw MobileQueryError.invalidConnection
        }
        return .init(id: id, name: name, host: host, port: port, username: username,
            database: database, tlsMode: tlsMode, remembersPassword: remembersPassword, requiresPassword: !password.isEmpty)
    }
}
