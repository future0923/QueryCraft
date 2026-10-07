protocol ConnectionTester: Sendable {
    func test(_ configuration: DatabaseConnectionConfiguration) async throws
    func test(_ configuration: DatabaseConnectionConfiguration, kafkaSASLMechanism: KafkaSASLMechanism) async throws
}

extension ConnectionTester {
    func test(_ configuration: DatabaseConnectionConfiguration, kafkaSASLMechanism: KafkaSASLMechanism) async throws {
        guard configuration.databaseType != .kafka || kafkaSASLMechanism == .plain
            || configuration.authentication.method == .none else { throw KafkaAuthenticationError.driverUpdateRequired }
        try await test(configuration)
    }
}
