import Foundation
import QueryCraftFeature

struct KafkaBrokerAddress: Equatable, Sendable {
    let host: String
    let port: Int
}

struct KafkaConnectionConfiguration: Equatable, Sendable {
    let bootstrapServers: [KafkaBrokerAddress]
    let username: String?
    let password: String?
    let tlsMode: ConnectionTLSMode
    var saslMechanism: KafkaSASLMechanism = .plain

    init(_ configuration: DatabaseConnectionConfiguration) throws {
        guard configuration.databaseType == .kafka else {
            throw DatabaseDriverError.configurationTypeMismatch(
                expected: .kafka,
                actual: configuration.databaseType
            )
        }
        guard configuration.authentication.method == .none
                || configuration.authentication.method == .usernamePassword
        else {
            throw DatabaseDriverError.unsupportedAuthentication(
                databaseType: .kafka,
                method: configuration.authentication.method
            )
        }

        let hostParts = configuration.host
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !hostParts.isEmpty else {
            throw KafkaError.invalidConfiguration("bootstrap server is empty")
        }
        guard (1...65_535).contains(configuration.port) else {
            throw KafkaError.invalidConfiguration("port is out of range")
        }

        bootstrapServers = try hostParts.map { hostPart in
            try Self.parseAddress(hostPart, defaultPort: configuration.port)
        }
        switch configuration.authentication {
        case let .usernamePassword(username, password):
            guard !username.isEmpty, !username.contains("\0") else {
                throw KafkaError.invalidConfiguration("SASL username is empty or contains NUL")
            }
            guard !(password ?? "").contains("\0") else {
                throw KafkaError.invalidConfiguration("SASL password contains NUL")
            }
            self.username = username
            self.password = password ?? ""
        case .none:
            username = nil
            password = nil
        case .apiKey:
            throw DatabaseDriverError.unsupportedAuthentication(
                databaseType: .kafka,
                method: .apiKey
            )
        }
        tlsMode = configuration.tlsMode
    }

    private static func parseAddress(
        _ value: String,
        defaultPort: Int
    ) throws -> KafkaBrokerAddress {
        if value.hasPrefix("[") {
            guard let closingBracket = value.firstIndex(of: "]") else {
                throw KafkaError.invalidConfiguration("invalid IPv6 host")
            }
            let host = String(value[value.index(after: value.startIndex)..<closingBracket])
            guard !host.isEmpty else {
                throw KafkaError.invalidConfiguration("invalid IPv6 host")
            }
            let suffix = value[value.index(after: closingBracket)...]
            if suffix.isEmpty {
                return KafkaBrokerAddress(host: host, port: defaultPort)
            }
            guard suffix.first == ":", let port = Int(suffix.dropFirst()), (1...65_535).contains(port) else {
                throw KafkaError.invalidConfiguration("invalid broker port")
            }
            return KafkaBrokerAddress(host: host, port: port)
        }

        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count <= 2, !components[0].isEmpty else {
            throw KafkaError.invalidConfiguration("invalid bootstrap server \(value)")
        }
        if components.count == 1 {
            return KafkaBrokerAddress(host: String(components[0]), port: defaultPort)
        }
        guard let port = Int(components[1]), (1...65_535).contains(port) else {
            throw KafkaError.invalidConfiguration("invalid broker port")
        }
        return KafkaBrokerAddress(host: String(components[0]), port: port)
    }
}
