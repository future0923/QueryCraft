import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceSchemaCatalogCoordinatorTests {
    @Test(arguments: [false, true])
    func retriesFailedColumnsWithoutRestartingAndCachesSuccessfulResults(
        emptyResult: Bool
    ) async throws {
        let reference = WorkspaceSchemaObjectReference(databaseName: "app", objectName: "users")
        let columns = emptyResult ? [] : [
            WorkspaceSchemaColumn(
                name: "name",
                type: "varchar(255)",
                ordinalPosition: 1,
                comment: "用户姓名"
            ),
        ]
        let recorder = CatalogRequestRecorder()
        await recorder.failNextColumnLoad()
        let coordinator = WorkspaceSchemaCatalogCoordinator(sessionFactory: PhasedCatalogSessionFactory(
            databases: ["app"],
            objectCatalog: [WorkspaceSchemaDatabase(name: "app", objects: [
                WorkspaceSchemaObject(
                    name: "users",
                    kind: .table,
                    columns: [],
                    comment: "系统用户表"
                ),
            ])],
            columnsByObject: [reference: columns],
            columnGate: nil,
            failsColumnLoad: false,
            recorder: recorder
        ))
        await coordinator.refresh(configuration: DatabaseConnectionConfiguration(
            host: "localhost", port: 3306, username: "test", password: nil,
            database: "app", tlsMode: .disabled
        ))
        let objectCatalogRevision = coordinator.snapshot.revision

        let failed = await coordinator.prepareColumns(for: [reference])
        #expect(failed.hasLoadedColumns(for: reference) == false)
        #expect(failed.revision == objectCatalogRevision)
        #expect(failed.database(named: "app")?.object(named: "users") != nil)

        let retried = await coordinator.prepareColumns(for: [reference])
        #expect(retried.hasLoadedColumns(for: reference))
        #expect(retried.database(named: "app")?.object(named: "users")?.columns == columns)
        #expect(retried.database(named: "app")?.object(named: "users")?.comment == "系统用户表")
        #expect(await recorder.requests() == [[reference], [reference]])

        _ = await coordinator.prepareColumns(for: [reference])
        #expect(await recorder.requests() == [[reference], [reference]])
        await coordinator.disconnect()
    }
}
