import QueryCraftFeature

struct KafkaDatabaseDriver: DatabaseDriver {
    let databaseType = DatabaseType.kafka

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> any WorkspaceSession {
        KafkaWorkspaceSession(
            configuration: try KafkaConnectionConfiguration(configuration)
        )
    }

    func testConnection(
        configuration: DatabaseConnectionConfiguration
    ) async throws {
        let session = KafkaWorkspaceSession(
            configuration: try KafkaConnectionConfiguration(configuration)
        )
        do {
            try await session.connect()
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    }
}
