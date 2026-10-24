import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobilePostgreSQLTests {
    @Test func postgresDraftHasIndependentDriverAndSchemaContext() throws {
        let draft = MobileConnectionDraft(); draft.name = "PG"; draft.driver = .postgresql
        draft.schemaName = "audit"; draft.database = "application"
        let profile = try draft.profile(), configuration = profile.configuration(password: "secret")
        #expect(draft.port == "5432"); #expect(draft.username == "postgres")
        #expect(configuration.driver == .postgresql); #expect(configuration.schemaName == "audit")
        #expect(configuration.postgreSQL.database == "application")
        #expect(configuration.selecting(database: "other", schema: "quoted.schema").postgreSQL.database == "other")
        let encoded = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(MobileConnectionProfile.self, from: encoded) == profile)
    }
    @Test func schemasAndOriginsDoNotCollideAcrossTablesOrExpressions() {
        let object = MobileDatabaseObject(database: "db", name: "sample", kind: .table, comment: "", schemaName: "audit")
        let columns = [MobileTableColumn(name: "name", type: "text", isNullable: true, key: "", defaultValue: nil, extra: "", comment: "audit comment")]
        let fields: [WorkspaceDatabaseDataColumn] = [
            .init(id: 0, name: "alias", type: "text", origin: .init(databaseName: "db", schemaName: "audit", tableName: "sample", columnName: "name")),
            .init(id: 1, name: "name", type: "text", origin: .init(databaseName: "db", schemaName: "public", tableName: "sample", columnName: "name")),
            .init(id: 2, name: "name", type: "integer", origin: nil)]
        let preview = MobileSQLPreview(result: .init(columns: fields.map(\.name)), metadata: fields)
        #expect(MobileColumnDetails.resolve(preview: preview, object: object, columns: columns) == ["text · audit comment", "text", "integer"])
        #expect(MobileGridData(preview: preview).metadata == fields)
        #expect(object.id != MobileDatabaseObject(database: "db", name: "sample", kind: .table, comment: "", schemaName: "public").id)
    }
    @Test func sharedPredicateQuotesIdentifiersAndLiteralWildcards() throws {
        let filter = WorkspaceDatabaseDataFilter(conditions: [.init(columnName: "na\"me", columnKind: .text, operation: .contains, value: "a%_'\\雪")])
        let sql = try PostgreSQLCatalog.filterPredicate(filter)
        #expect(sql.contains("\"na\"\"me\"::text LIKE")); #expect(sql.contains(PostgreSQLCatalog.literal("%a\\%\\_'\\\\雪%")))
    }
    @Test func postgresWorkspaceEnablesOwnSessionAndKeepsMySQLSchemaEditingDisabled() {
        let p = MobileConnectionProfile(id: UUID(), name: "PG", host: "127.0.0.1", port: 5432, username: "postgres", database: "db", tlsMode: .disabled, remembersPassword: false, requiresPassword: false, driver: .postgresql, schemaName: "audit")
        let workspace = MobileDatabaseWorkspace(profile: p, password: nil, service: MobileMySQLService())
        #expect(workspace.browser.supportsSchemas); #expect(workspace.browser.supportsEditing); #expect(!workspace.browser.supportsSchemaEditing)
        #expect(workspace.query.schemaName == "audit"); #expect(workspace.query.supportsTransactions)
        #expect(!workspace.query.allowsDataMutation()); #expect(workspace.query.allowsSQLExecution())
    }
    @Test func historyKeepsSchemaAndDecodesLegacyItems() throws {
        let item = MobileQueryHistoryItem(id: UUID(), profileID: UUID(), database: "db", sql: "SELECT 1", date: Date(), schemaName: "audit")
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(MobileQueryHistoryItem.self, from: data).schemaName == "audit")
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "schemaName")
        #expect(try JSONDecoder().decode(MobileQueryHistoryItem.self, from: JSONSerialization.data(withJSONObject: legacy)).schemaName == nil)
    }
    private func config() throws -> MobileSQLConfiguration {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"].flatMap(Int.init))
        return .init(host: "127.0.0.1", port: port, username: "proof_reader", password: "querycraft-proof-pg", database: "querycraft_ios_pg", tlsMode: .disabled, driver: .postgresql)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"] != nil)) func realCatalogSchemaCommentsAndPagination() async throws {
        let config = try config(), service = MobilePostgreSQLService()
        #expect(try await service.databases(configuration: config).contains("querycraft_ios_pg"))
        #expect(try await service.schemas(configuration: config, database: "querycraft_ios_pg").contains("audit"))
        let catalog = try await service.objects(configuration: config, database: "querycraft_ios_pg", search: "amu", kind: .table)
        #expect(catalog.objects.count == 2)
        let object = try #require(catalog.objects.first { $0.schemaName == "audit" })
        let columns = try await service.columns(configuration: config, object: object)
        #expect(columns.first { $0.name == "name" }?.comment == "audit name")
        #expect(columns.first { $0.name == "id" }?.key == "PRI")
        let views = try await service.objects(configuration: config, database: "querycraft_ios_pg", search: "", kind: .view)
        let materialized = try #require(views.objects.first { $0.name == "user_snapshot" })
        let viewColumns = try await service.columns(configuration: config, object: materialized)
        #expect(viewColumns.first { $0.name == "name" }?.comment == "snapshot name")
        #expect(try await service.page(configuration: config, object: materialized, columns: viewColumns, offset: 0, size: 100, sortColumn: "id", ascending: true, filter: .empty).preview.result.rows.count == 2)
        let page = try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 1, sortColumn: "id", ascending: true, filter: .empty)
        #expect(page.hasNextPage); #expect(page.hasStableOrder)
        #expect(page.preview.workspaceColumns[1].origin?.schemaName == "audit")
        #expect(MobileColumnDetails.resolve(preview: page.preview, object: object, columns: columns)[1].contains("audit name"))
        let filter = WorkspaceDatabaseDataFilter(conditions: [.init(columnName: "name", columnKind: .text, operation: .equal, value: "你好 PG")])
        let filtered = try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 100, sortColumn: nil, ascending: true, filter: filter)
        #expect(filtered.preview.result.rows.count == 1)
        let browser = MobileBrowserModel(configuration: config, service: service, supportsEditing: false)
        await browser.loadDatabases().value; browser.selectDatabase("querycraft_ios_pg"); await browser.loadObjects()?.value
        browser.selectSchema(nil); await browser.loadObjects()?.value
        #expect(browser.selectedSchema == nil)
        browser.selectSchema("audit"); browser.search = "amu"
        #expect(browser.visibleObjects.count == 1); #expect(browser.visibleObjects.first?.schemaName == "audit")
        #expect(browser.objectsInSelectedSchema.count == 1)
        let export = MobileDataExportSnapshot.table(page, configuration: config, service: service)
        #expect(export.tableIdentifierParts == ["audit", "admin_user"])
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"] != nil)) func realAliasJoinExpressionEmptyResultAndQuotedSchema() async throws {
        let executor = MobilePostgreSQLExecutor(), config = try config()
        let sql = "SELECT a.name AS alias, p.name AS name, length(a.name) AS name FROM audit.admin_user a JOIN public.admin_user p ON a.id=p.id ORDER BY a.id"
        let preview = try await executor.preview(configuration: config, sql: sql, maximumRows: 10, maximumBytes: 4096)
        #expect(preview.workspaceColumns[0].origin?.schemaName == "audit")
        #expect(preview.workspaceColumns[1].origin?.schemaName == "public")
        #expect(preview.workspaceColumns[2].origin == nil)
        #expect(preview.columnDetails?[0].contains("audit name") == true)
        #expect(preview.columnDetails?[1].contains("public name") == true)
        #expect(preview.columnDetails?[2].contains("name") == false)
        let empty = try await executor.preview(configuration: config, sql: "SELECT name AS alias, id+1 AS expression FROM audit.admin_user WHERE id<0", maximumRows: 10, maximumBytes: 4096)
        #expect(empty.result.rows.isEmpty); #expect(empty.workspaceColumns.count == 2)
        #expect(empty.workspaceColumns[0].origin?.schemaName == "audit"); #expect(empty.workspaceColumns[1].origin == nil)
        let quoted = try await executor.execute(configuration: config.selecting(database: "querycraft_ios_pg", schema: "schema.with.dot"), sql: "SELECT name FROM \"table.with.dot\"")
        #expect(quoted.rows.first?.first == "quoted schema")
        let inSchema = try await executor.execute(configuration: config.selecting(database: "querycraft_ios_pg", schema: "audit"), sql: "SELECT name FROM admin_user ORDER BY id LIMIT 1")
        #expect(inSchema.rows.first?.first == "你好 PG")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"] != nil)) func realQueryEntryAndHistoryRestoreOriginalSchema() async throws {
        let configuration = try config()
        let profile = MobileConnectionProfile(id: UUID(), name: "PG history", host: configuration.host, port: configuration.port,
            username: configuration.username, database: "querycraft_ios_pg", tlsMode: .disabled, remembersPassword: false,
            requiresPassword: true, driver: .postgresql, schemaName: "audit")
        let app = MobileApplicationModel(repository: PostgreSQLTestLibrary(profile))
        app.open(profile, suppliedPassword: configuration.password)
        let workspace = try #require(app.workspace)
        await workspace.browser.loadDatabases().value; await workspace.browser.loadObjects()?.value
        workspace.query.sql = "SELECT name FROM admin_user ORDER BY id LIMIT 1"
        await workspace.query.execute()?.value
        #expect(workspace.query.errorMessage == nil)
        #expect(workspace.query.result?.rows.first?.first == "你好 PG")
        let history = try #require(app.library.history.first)
        #expect(history.schemaName == "audit")
        workspace.browser.selectSchema("public"); workspace.query.schemaName = "public"
        app.recordQuery(sql: history.sql, database: history.database, profileID: profile.id, schemaName: "public")
        #expect(app.library.history.count == 2)
        app.restore(history)
        #expect(workspace.query.schemaName == "audit"); #expect(workspace.browser.selectedSchema == "audit")
        await workspace.query.execute()?.value
        #expect(workspace.query.errorMessage == nil)
        #expect(workspace.query.result?.rows.first?.first == "你好 PG")
        app.showLibrary()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"] != nil)) func realBoundedNativeReadByteaNullAndCancellation() async throws {
        let config = try config(), executor = MobilePostgreSQLExecutor()
        let truncated = try await executor.preview(configuration: config, sql: "SELECT n FROM generate_series(1,1000000) n", maximumRows: 3, maximumBytes: 4096)
        #expect(truncated.isTruncated); #expect(truncated.result.rows.count == 3)
        #expect(truncated.workspaceColumns.first?.type == "integer")
        let bytes = try await executor.preview(configuration: config, sql: "SELECT repeat('x',1000) AS value", maximumRows: 10, maximumBytes: 100)
        #expect(bytes.isTruncated); #expect(bytes.result.rows.isEmpty)
        let values = try await executor.preview(configuration: config, sql: "SELECT decode('0041ff','hex') AS payload, NULL::text AS nullable, ''::text AS blank", maximumRows: 10, maximumBytes: 4096)
        #expect(values.result.rows[0][0] == "\\x0041ff"); #expect(values.result.rows[0][1] == nil); #expect(values.result.rows[0][2] == "")
        let marker = "querycraft_cancel_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let observer = LibPQClient(configuration: config.postgreSQL)
        try await observer.connect()
        let task = Task { try await executor.execute(configuration: config, sql: "SELECT pg_sleep(10) /* \(marker) */") }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        var running = false
        while ContinuousClock.now < deadline {
            let activity = try await observer.query("SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND state = 'active' AND query LIKE '%\(marker)%'")
            if activity.rows.first?.first == "1" { running = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(running)
        let cancelledAt = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelledAt.duration(to: .now) < .seconds(3))
        await observer.close()
        #expect(try await executor.execute(configuration: config, sql: "SELECT 1").rows.first?.first == "1")
        await #expect(throws: (any Error).self) { try await executor.execute(configuration: config, sql: "DELETE FROM audit.admin_user") }
        await #expect(throws: (any Error).self) { try await executor.execute(configuration: config, sql: "SELECT 1; COMMIT; SELECT 2") }
    }
}

@MainActor private final class PostgreSQLTestLibrary: MobileLibraryPersisting {
    var state: MobileLibraryState
    init(_ profile: MobileConnectionProfile) { state = .init(profiles: [profile]) }
    func load() throws -> MobileLibraryState { state }
    func write(_ state: MobileLibraryState) throws { self.state = state }
}
