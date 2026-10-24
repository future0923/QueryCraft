import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

struct MobileSQLSchemaTests {
    private func config(_ host: String = "one", port: Int = 3306) -> MobileSQLConfiguration {
        .init(host: host, port: port, username: "reader", password: "test", database: "db", tlsMode: .required)
    }

    @Test @MainActor func metadataIsLazyCachedAndColumnLoadsKeepTrueNamesTypesComments() async throws {
        let service = SchemaFixture(), model = MobileSQLSchemaCatalog(service: service)
        model.configure(config())
        #expect(model.snapshot.databases.isEmpty)
        #expect(await service.catalogCalls == 0)
        _ = await model.load(); _ = await model.load()
        #expect(await service.catalogCalls == 1)
        let reference = WorkspaceSchemaObjectReference(databaseName: "db", objectName: "users")
        let snapshot = await model.prepareColumns([reference])
        #expect(snapshot.database(named: "db")?.object(named: "users")?.columns.first?.comment == "actual comment")
        #expect(snapshot.database(named: "db")?.object(named: "users")?.columns.first?.ordinalPosition == 3)
        #expect(snapshot.hasLoadedColumns(for: reference))
        _ = await model.prepareColumns([reference])
        #expect(await service.columnCalls == 1)
        _ = await model.prepareColumns([])
        #expect(model.snapshot.loadedColumnObjects.isEmpty)
        #expect(model.snapshot.database(named: "db")?.object(named: "users")?.columns.isEmpty == true)
        model.invalidate()
        _ = await model.load()
        #expect(await service.catalogCalls == 2)
        #expect(model.snapshot.loadedColumnObjects.isEmpty)
    }

    @Test @MainActor func failureKeepsKnownCatalogAndCanRetryWithoutInventingFields() async throws {
        let service = SchemaFixture(), model = MobileSQLSchemaCatalog(service: service)
        model.configure(config()); _ = await model.load()
        await service.failColumns()
        let reference = WorkspaceSchemaObjectReference(databaseName: "db", objectName: "users")
        let before = model.snapshot
        _ = await model.prepareColumns([reference])
        #expect(model.snapshot == before)
        #expect(model.errorMessage != nil)
        #expect(!model.snapshot.hasLoadedColumns(for: reference))
        _ = await model.prepareColumns([reference])
        #expect(model.snapshot.hasLoadedColumns(for: reference))
        #expect(model.errorMessage == nil)
    }

    @Test @MainActor func oldConnectionReplyCannotPublishAfterDatabaseOrCredentialChange() async throws {
        let service = ControlledSchema(), model = MobileSQLSchemaCatalog(service: service)
        model.configure(config("old"))
        let old = Task { await model.load() }
        try await wait { await service.count == 1 }
        model.configure(config("new"))
        let new = Task { await model.load() }
        try await wait { await service.count == 2 }
        await service.complete(1, database: "new"); _ = await new.value
        #expect(model.snapshot.databases.map(\.name) == ["new"])
        await service.complete(0, database: "old"); _ = await old.value
        #expect(model.snapshot.databases.map(\.name) == ["new"])
        #expect(!model.isLoading); #expect(model.errorMessage == nil)
    }

    @Test func realCatalogSharedQueriesSupportViewsCrossDatabaseAndAliasCompletion() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init))
        let configuration = MobileSQLConfiguration(host: "127.0.0.1", port: port, username: "proof_reader", password: "querycraft-proof-reader", database: "querycraft_ios_proof", tlsMode: .required)
        let service = MobileMySQLService()
        let databases = try await service.editorCatalog(configuration: configuration)
        #expect(databases.contains { $0.name == "querycraft_ios_other" })
        #expect(databases.first { $0.name == "querycraft_ios_proof" }?.objects.contains { $0.name == "sample_view" && $0.kind == .view } == true)
        let refs = [WorkspaceSchemaObjectReference(databaseName: "querycraft_ios_proof", objectName: "admin_user"),
                    .init(databaseName: "querycraft_ios_other", objectName: "epoch_values")]
        let values = try await service.editorColumns(configuration: configuration, references: refs)
        #expect(values.first { $0.reference == refs[0] }?.columns.count == 78)
        #expect(values.first { $0.reference == refs[1] }?.columns.first { $0.name == "created_at" }?.comment == "Unix seconds")
        let context = try await service.editorContext(configuration: configuration)
        #expect(context.dialect == .mysql)
        let source = SQLSourceSnapshot(revision: .init(1), text: "SELECT u.us FROM admin_user u")
        let parser = try SQLStructuralParser(), snapshot = try await parser.parse(source)
        let catalog = WorkspaceSchemaCatalogSnapshot(revision: 1, databases: databases.map { db in
            .init(name: db.name, objects: db.objects.map { object in
                let ref = WorkspaceSchemaObjectReference(databaseName: db.name, objectName: object.name)
                return .init(name: object.name, kind: object.kind, columns: values.first { $0.reference == ref }?.columns ?? [], comment: object.comment)
            })
        }, loadedColumnObjects: Set(refs))
        let result = try #require(try SQLCompletionEngine.completions(for: .init(source: source,
            cursorLocation: (source.text as NSString).range(of: "u.us").upperBound,
            parseSnapshot: snapshot, schemaCatalog: catalog, defaultDatabase: "querycraft_ios_proof")))
        #expect(result.items.contains { $0.label == "user_name" && $0.kind == .column })
        #expect(result.referencedSchemaObjects.contains(refs[0]))
    }

    @Test @MainActor func repeatedActiveRelationsCoalesceAndInactivePendingColumnsCannotPublish() async throws {
        let service = ColumnGate(), model = MobileSQLSchemaCatalog(service: service)
        model.configure(config()); _ = await model.load()
        let reference = WorkspaceSchemaObjectReference(databaseName: "db", objectName: "users")
        let first = Task { await model.prepareColumns([reference]) }
        try await wait { await service.count == 1 }
        let second = Task { await model.prepareColumns([reference]) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await service.count == 1)
        _ = await model.prepareColumns([])
        await service.complete(0); _ = await first.value; _ = await second.value
        #expect(model.snapshot.loadedColumnObjects.isEmpty)
        #expect(model.snapshot.database(named: "db")?.object(named: "users")?.columns.isEmpty == true)
        #expect(!model.isLoading)
        let retry = Task { await model.prepareColumns([reference]) }
        try await wait { await service.count == 2 }
        await service.complete(1); _ = await retry.value
        #expect(model.snapshot.hasLoadedColumns(for: reference))
    }

    @Test @MainActor func backgroundCancelsLazyMetadataAndKeepsCachedSnapshotUntilExplicitLoad() async throws {
        let service = ControlledSchema(), model = MobileSQLSchemaCatalog(service: service)
        model.configure(config())
        let initial = Task { await model.load() }
        try await wait { await service.count == 1 }
        await service.complete(0, database: "cached"); _ = await initial.value
        let cached = model.snapshot
        model.invalidate()
        let refresh = Task { await model.load() }
        try await wait { await service.count == 2 }
        model.setBackgrounded(true)
        await service.complete(1, database: "late"); _ = await refresh.value
        #expect(model.snapshot == cached); #expect(!model.isLoading)
        _ = await model.load(); #expect(await service.count == 2)
        model.setBackgrounded(false); #expect(await service.count == 2)
        let retry = Task { await model.load() }
        try await wait { await service.count == 3 }
        await service.complete(2, database: "fresh"); _ = await retry.value
        #expect(model.snapshot.database(named: "fresh") != nil)
    }

    private func wait(_ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor SchemaFixture: MobileSQLMetadataProviding {
    private(set) var catalogCalls = 0
    private(set) var columnCalls = 0
    private var fails = false
    func failColumns() { fails = true }
    func editorCatalog(configuration: MobileSQLConfiguration) async throws -> [WorkspaceSchemaDatabase] {
        catalogCalls += 1
        return [.init(name: "db", objects: [.init(name: "users", kind: .table, columns: [])])]
    }
    func editorColumns(configuration: MobileSQLConfiguration, references: [WorkspaceSchemaObjectReference]) async throws -> [WorkspaceSchemaObjectColumns] {
        columnCalls += 1
        if fails { fails = false; throw CocoaError(.fileReadNoPermission) }
        return references.map { .init(reference: $0, columns: [.init(name: "name", type: "varchar(80)", ordinalPosition: 3, comment: "actual comment")]) }
    }
    func editorContext(configuration: MobileSQLConfiguration) async throws -> SQLHighlightContext { .init(databaseType: .mysql) }
}

private actor ControlledSchema: MobileSQLMetadataProviding {
    private var continuations: [CheckedContinuation<[WorkspaceSchemaDatabase], Never>] = []
    var count: Int { continuations.count }
    func editorCatalog(configuration: MobileSQLConfiguration) async throws -> [WorkspaceSchemaDatabase] {
        await withCheckedContinuation { continuations.append($0) }
    }
    func complete(_ index: Int, database: String) { continuations[index].resume(returning: [.init(name: database, objects: [])]) }
    func editorColumns(configuration: MobileSQLConfiguration, references: [WorkspaceSchemaObjectReference]) async throws -> [WorkspaceSchemaObjectColumns] { [] }
    func editorContext(configuration: MobileSQLConfiguration) async throws -> SQLHighlightContext { .init(databaseType: .mysql) }
}

private actor ColumnGate: MobileSQLMetadataProviding {
    private var values: [([WorkspaceSchemaObjectReference], CheckedContinuation<[WorkspaceSchemaObjectColumns], Never>)] = []
    var count: Int { values.count }
    func editorCatalog(configuration: MobileSQLConfiguration) async throws -> [WorkspaceSchemaDatabase] {
        [.init(name: "db", objects: [.init(name: "users", kind: .table, columns: [])])]
    }
    func editorColumns(configuration: MobileSQLConfiguration, references: [WorkspaceSchemaObjectReference]) async throws -> [WorkspaceSchemaObjectColumns] {
        await withCheckedContinuation { values.append((references, $0)) }
    }
    func complete(_ index: Int) {
        values[index].1.resume(returning: values[index].0.map { .init(reference: $0, columns: [.init(name: "id", type: "int", ordinalPosition: 1)]) })
    }
    func editorContext(configuration: MobileSQLConfiguration) async throws -> SQLHighlightContext { .init(databaseType: .mysql) }
}
