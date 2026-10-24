import Foundation
import Observation
import QueryCraftMobileCore
import QueryCraftMobileTransport

struct MobileConnectionProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var database: String
    var tlsMode: ConnectionTLSMode
    var remembersPassword: Bool
    var requiresPassword: Bool
    var driver: MobileDriver = .mysql
    var authentication: MobileAuthentication = .usernamePassword
    var schemaName: String? = nil

    func configuration(password: String?, database: String? = nil) -> MobileSQLConfiguration {
        .init(host: host, port: port, username: username, password: password,
              database: database ?? (self.database.isEmpty ? nil : self.database), tlsMode: tlsMode, driver: driver, schemaName: schemaName)
    }
}

@MainActor @Observable
final class MobileConnectionDraft: Identifiable {
    let id: UUID
    var driver: MobileDriver { didSet { if oldValue != driver { port = String(driver.port); username = driver == .postgresql ? "postgres" : driver == .mysql || driver == .doris ? "root" : ""; database = ""; schemaName = ""; password = ""; tlsMode = driver == .redis || driver == .doris ? .disabled : .required; authentication = .usernamePassword } } }
    var authentication: MobileAuthentication
    var name: String
    var host: String
    var port: String
    var username: String
    var password: String
    var database: String
    var schemaName: String
    var tlsMode: ConnectionTLSMode
    var remembersPassword: Bool
    var message: String?
    var isTesting = false

    init(profile: MobileConnectionProfile? = nil, password: String = "") {
        id = profile?.id ?? UUID()
        driver = profile?.driver ?? .mysql
        authentication = profile?.authentication ?? .usernamePassword
        name = profile?.name ?? ""
        host = profile?.host ?? "127.0.0.1"
        port = profile.map { String($0.port) } ?? "3306"
        username = profile?.username ?? "root"
        self.password = password
        database = profile?.database ?? ""
        schemaName = profile?.schemaName ?? ""
        tlsMode = profile?.tlsMode ?? .required
        remembersPassword = profile?.remembersPassword ?? false
    }

    func profile() throws -> MobileConnectionProfile {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !host.isEmpty, (!driver.isSQL || !username.isEmpty),
              let port = Int(port), (1...65535).contains(port), !host.contains("\0"),
              !database.contains("\0"), !schemaName.contains("\0"), !username.contains("\0"), !password.contains("\0"),
              (driver == .elasticsearch || driver == .postgresql || tlsMode == .disabled || tlsMode == .required),
              (driver != .redis || tlsMode == .disabled && RedisConnectionConfiguration.databaseIndex(from: database) != nil),
              (driver == .elasticsearch || authentication == .usernamePassword) else {
            throw MobileQueryError.invalidConnection
        }
        return .init(id: id, name: name, host: host, port: port, username: username,
            database: database, tlsMode: tlsMode, remembersPassword: remembersPassword, requiresPassword: authentication != .none && !password.isEmpty, driver: driver, authentication: authentication, schemaName: schemaName.isEmpty ? nil : schemaName)
    }
}

// Decode pre-driver libraries as MySQL without changing their IDs or credentials.
extension MobileConnectionProfile {
    enum CodingKeys: String, CodingKey { case id, name, host, port, username, database, tlsMode, remembersPassword, requiresPassword, driver, authentication, schemaName }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        database = try c.decode(String.self, forKey: .database)
        tlsMode = try c.decode(ConnectionTLSMode.self, forKey: .tlsMode)
        remembersPassword = try c.decode(Bool.self, forKey: .remembersPassword)
        requiresPassword = try c.decode(Bool.self, forKey: .requiresPassword)
        driver = try c.decodeIfPresent(MobileDriver.self, forKey: .driver) ?? .mysql
        schemaName = try c.decodeIfPresent(String.self, forKey: .schemaName)
        authentication = try c.decodeIfPresent(MobileAuthentication.self, forKey: .authentication) ?? .usernamePassword
    }
}

enum MobileDriver: String, Codable, CaseIterable, Identifiable, Sendable {
    case mysql, postgresql, doris, redis, elasticsearch
    var id: Self { self }
    var title: String { switch self { case .mysql: "MySQL"; case .postgresql: "PostgreSQL"; case .doris: "Doris"; case .redis: "Redis"; case .elasticsearch: "Elasticsearch" } }
    var port: Int { switch self { case .mysql: 3306; case .postgresql: 5432; case .doris: 9030; case .redis: 6379; case .elasticsearch: 9200 } }
    var isSQL: Bool { self == .mysql || self == .postgresql || self == .doris }
}
enum MobileAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case usernamePassword, apiKey, none
    var id: Self { self }
    var title: String { switch self { case .usernamePassword: "用户名与密码"; case .apiKey: "API Key"; case .none: "无认证" } }
}
