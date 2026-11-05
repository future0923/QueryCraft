import QueryCraftFeature

struct MilvusDatabaseDriver: DatabaseDriver {
    let databaseType = DatabaseType.milvus

    func makeSession(configuration: DatabaseConnectionConfiguration) async throws -> any WorkspaceSession {
        try MilvusWorkspaceSession(configuration: MilvusConnectionConfiguration(configuration))
    }

    func testConnection(configuration: DatabaseConnectionConfiguration) async throws {
        let session = try MilvusWorkspaceSession(configuration: MilvusConnectionConfiguration(configuration))
        do { try await session.connect(); await session.close() }
        catch { await session.close(); throw error }
    }
}
