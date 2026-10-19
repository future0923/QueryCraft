import Foundation

protocol SchemaComparisonTableListing: Sendable {
    func tables(configuration: DatabaseConnectionConfiguration) async throws -> [String]
}

struct SchemaComparisonTableLoader: SchemaComparisonTableListing {
    let sessionFactory: any WorkspaceSessionFactory
    func tables(configuration: DatabaseConnectionConfiguration) async throws -> [String] {
        guard let database = configuration.database, !database.isEmpty else { throw SchemaComparisonError.invalidDatabase }
        let session = await sessionFactory.makeSession(configuration: configuration)
        do {
            try Task.checkCancellation()
            let connecting = Task { try await session.connect() }
            try await connecting.value
            try Task.checkCancellation()
            let objects = try await session.fetchObjects(in: database)
            try Task.checkCancellation()
            await session.close()
            return objects.filter { $0.kind == .table || $0.kind == .view }.map(\.name).sorted()
        } catch {
            await session.close()
            throw error
        }
    }
}
