import Foundation

struct ConnectionProfileDraft: Equatable, Sendable {
    var name = ""
    var groupID: ConnectionGroup.ID?
    var databaseType = DatabaseType.mysql
    var databaseProduct = DatabaseProduct.mysql
    var host = "localhost"
    var port = 3306
    var username = "root"
    var authenticationMethod = DatabaseConnectionAuthenticationMethod.usernamePassword
    var password = ""
    var defaultDatabase = ""
    var tlsMode = ConnectionTLSMode.verifyIdentity
    var savePassword = true

    init(databaseProduct: DatabaseProduct = .mysql) {
        self.databaseProduct = databaseProduct
        databaseType = databaseProduct.databaseType
        port = databaseProduct.defaultPort
        username = databaseProduct.defaultUsername
        if databaseProduct == .redis {
            defaultDatabase = "DB 0"
            tlsMode = .disabled
        } else if databaseProduct == .elasticsearch {
            tlsMode = .disabled
        }
    }

    init(databaseType: DatabaseType) {
        self.init(databaseProduct: .defaultProduct(for: databaseType))
    }

    init(profile: ConnectionProfile, password: String = "") {
        name = profile.name
        groupID = profile.groupID
        databaseType = profile.databaseType
        databaseProduct = profile.databaseProduct
        host = profile.host
        port = profile.port
        username = profile.username
        authenticationMethod = profile.authenticationMethod
        self.password = password
        defaultDatabase = profile.defaultDatabase ?? ""
        tlsMode = profile.tlsMode
        savePassword = profile.storesCredential
    }

    func makeProfile(
        id: UUID = UUID(),
        sortIndex: Int = 0,
        createdAt: Date = .now
    ) throws -> ConnectionProfile {
        let name = name.trimmed
        let configuration = try makeConnectionConfiguration()

        guard !name.isEmpty else {
            throw ConnectionProfileValidationError.missingName
        }

        return ConnectionProfile(
            id: id,
            name: name,
            groupID: groupID,
            databaseType: configuration.databaseType,
            databaseProduct: configuration.databaseProduct,
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            authenticationMethod: configuration.authentication.method,
            defaultDatabase: configuration.database,
            tlsMode: configuration.tlsMode,
            storesCredential: authenticationMethod != .none
                && savePassword
                && !password.isEmpty,
            sortIndex: sortIndex,
            createdAt: createdAt
        )
    }

    func makeConnectionConfiguration() throws
        -> DatabaseConnectionConfiguration
    {
        let host = host.trimmed
        let username = username.trimmed

        guard !host.isEmpty else {
            throw ConnectionProfileValidationError.missingHost
        }
        guard (1...65_535).contains(port) else {
            throw ConnectionProfileValidationError.invalidPort
        }
        guard authenticationMethod != .usernamePassword
                || databaseProduct == .redis
                || !username.isEmpty
        else {
            throw ConnectionProfileValidationError.missingUsername
        }

        let authentication: DatabaseConnectionAuthentication = switch authenticationMethod {
        case .usernamePassword:
            .usernamePassword(
                username: username,
                password: password.nilIfEmpty
            )
        case .apiKey:
            .apiKey(password.nilIfEmpty)
        case .none:
            .none
        }

        return DatabaseConnectionConfiguration(
            databaseType: databaseType,
            databaseProduct: databaseProduct,
            host: host,
            port: port,
            authentication: authentication,
            database: defaultDatabase.trimmed.nilIfEmpty,
            tlsMode: tlsMode
        )
    }

    mutating func selectDatabaseType(_ newType: DatabaseType) {
        selectDatabaseProduct(.defaultProduct(for: newType))
    }

    mutating func selectDatabaseProduct(_ newProduct: DatabaseProduct) {
        guard databaseProduct != newProduct else { return }
        let previousProduct = databaseProduct
        databaseProduct = newProduct
        databaseType = newProduct.databaseType
        if port == previousProduct.defaultPort {
            port = newProduct.defaultPort
        }
        if username == previousProduct.defaultUsername {
            username = newProduct.defaultUsername
        }
        if newProduct == .redis {
            if defaultDatabase.isEmpty { defaultDatabase = "DB 0" }
            tlsMode = .disabled
            authenticationMethod = .usernamePassword
        } else if newProduct == .elasticsearch {
            if defaultDatabase == "DB 0" { defaultDatabase = "" }
            tlsMode = .disabled
        } else if previousProduct == .redis {
            if defaultDatabase == "DB 0" { defaultDatabase = "" }
            tlsMode = .verifyIdentity
        } else if previousProduct == .elasticsearch {
            tlsMode = .verifyIdentity
            authenticationMethod = .usernamePassword
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
