import Foundation
import Observation
import QueryCraftMobileCore
import QueryCraftMobileTransport

protocol MobileSQLMetadataProviding: Sendable {
    func editorCatalog(configuration: MobileSQLConfiguration) async throws -> [WorkspaceSchemaDatabase]
    func editorColumns(configuration: MobileSQLConfiguration, references: [WorkspaceSchemaObjectReference]) async throws -> [WorkspaceSchemaObjectColumns]
    func editorContext(configuration: MobileSQLConfiguration) async throws -> SQLHighlightContext
}

extension MobileMySQLService: MobileSQLMetadataProviding {
    func editorCatalog(configuration: MobileSQLConfiguration) async throws -> [WorkspaceSchemaDatabase] {
        let names = try await databases(configuration: configuration)
        let result = try await executor.execute(configuration: metadataConfiguration(configuration), sql: MySQLSchemaCatalog.objectsQuery)
        return MySQLSchemaCatalog.databases(names, rows: result.dictionaryRows)
    }
    func editorColumns(configuration: MobileSQLConfiguration, references: [WorkspaceSchemaObjectReference]) async throws -> [WorkspaceSchemaObjectColumns] {
        guard !references.isEmpty else { return [] }
        let result = try await executor.execute(configuration: metadataConfiguration(configuration), sql: MySQLSchemaCatalog.columnsQuery(references))
        return MySQLSchemaCatalog.columns(references, rows: result.dictionaryRows)
    }
    func editorContext(configuration: MobileSQLConfiguration) async throws -> SQLHighlightContext {
        let result = try await executor.execute(configuration: metadataConfiguration(configuration), sql: "SELECT @@SESSION.sql_mode")
        guard let mode = result.rows.first?.first ?? nil else { throw MobileQueryError.invalidServerMetadata }
        return .init(databaseType: .mysql, ansiQuotes: mode.uppercased().split(separator: ",").contains("ANSI_QUOTES"))
    }
    private func metadataConfiguration(_ config: MobileSQLConfiguration) -> MobileSQLConfiguration {
        .init(host: config.host, port: config.port, username: config.username, password: config.password, database: nil, tlsMode: config.tlsMode)
    }
}

/// Same schema snapshot consumed by the desktop completion engine. A separate
/// connection/generation prevents metadata work from changing query results.
@MainActor @Observable final class MobileSQLSchemaCatalog {
    private(set) var snapshot = WorkspaceSchemaCatalogSnapshot.empty
    private(set) var context = SQLHighlightContext(databaseType: .mysql)
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isBackgrounded = false
    private let service: any MobileSQLMetadataProviding
    @ObservationIgnored private var configuration: MobileSQLConfiguration?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var columnTask: Task<Void, Never>?
    @ObservationIgnored private var columnID = UUID()
    @ObservationIgnored private var pendingColumns = Set<WorkspaceSchemaObjectReference>()
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var retryAfter = ContinuousClock.now

    init(service: any MobileSQLMetadataProviding = MobileMySQLService()) { self.service = service }

    func configure(_ configuration: MobileSQLConfiguration?) {
        guard self.configuration != configuration else { return }
        invalidate(); self.configuration = configuration
        context = .init(databaseType: configuration?.driver == .postgresql ? .postgresql : configuration?.driver == .doris ? .doris : .mysql)
        publish([])
    }

    func invalidate() {
        generation = UUID(); columnID = UUID()
        task?.cancel(); task = nil; columnTask?.cancel(); columnTask = nil
        loaded = false; isLoading = false; errorMessage = nil; retryAfter = .now
        pendingColumns = []
    }

    func setBackgrounded(_ backgrounded: Bool) {
        guard isBackgrounded != backgrounded else { return }
        isBackgrounded = backgrounded
        if backgrounded { invalidate() }
    }

    func load(force: Bool = false) async -> WorkspaceSchemaCatalogSnapshot {
        guard !isBackgrounded, let configuration else { return snapshot }
        if force, errorMessage != nil { retryAfter = .now }
        if task == nil, !loaded, ContinuousClock.now >= retryAfter {
            let token = generation, service = service
            isLoading = true
            task = Task { [weak self] in
                do {
                    let databases = try await service.editorCatalog(configuration: configuration)
                    try Task.checkCancellation()
                    let context = try await service.editorContext(configuration: configuration)
                    try Task.checkCancellation()
                    guard let self, self.generation == token else { return }
                    self.publish(databases); self.context = context; self.loaded = true
                    self.errorMessage = nil; self.isLoading = false; self.task = nil
                } catch {
                    guard let self, self.generation == token else { return }
                    self.isLoading = false; self.task = nil
                    if !(error is CancellationError) { self.errorMessage = MobileConnectionFeedback.reading(error) }
                    self.retryAfter = .now.advanced(by: .seconds(2))
                }
            }
        }
        await task?.value
        return snapshot
    }

    func prepareColumns(_ requested: [WorkspaceSchemaObjectReference]) async -> WorkspaceSchemaCatalogSnapshot {
        guard !isBackgrounded, let configuration, loaded else { return snapshot }
        let active = Set(requested)
        if !pendingColumns.isSubset(of: active) {
            columnID = UUID(); columnTask?.cancel(); columnTask = nil; pendingColumns = []; isLoading = false
        }
        // Desktop retains relation columns only for the active query scope.
        if !snapshot.loadedColumnObjects.isSubset(of: active) {
            let databases = snapshot.databases.map { database in
                WorkspaceSchemaDatabase(name: database.name, objects: database.objects.map { object in
                    let reference = WorkspaceSchemaObjectReference(databaseName: database.name, objectName: object.name)
                    return active.contains(reference) ? object : .init(name: object.name, kind: object.kind, columns: [], comment: object.comment)
                })
            }
            revision += 1
            snapshot = .init(revision: revision, databases: databases, loadedColumnObjects: snapshot.loadedColumnObjects.intersection(active))
        }
        let references = Array(Set(requested)).filter { !snapshot.hasLoadedColumns(for: $0) }
        guard !references.isEmpty else { return snapshot }
        if columnTask != nil, pendingColumns == Set(references) {
            await columnTask?.value; return snapshot
        }
        columnTask?.cancel(); let id = UUID(); columnID = id
        pendingColumns = Set(references); isLoading = true
        let token = generation, service = service
        columnTask = Task { [weak self] in
            do {
                let values = try await service.editorColumns(configuration: configuration, references: references)
                try Task.checkCancellation()
                guard let self, self.generation == token, self.columnID == id else { return }
                var loaded = self.snapshot.loadedColumnObjects
                let databases = self.snapshot.databases.map { database in
                    WorkspaceSchemaDatabase(name: database.name, objects: database.objects.map { object in
                        let reference = WorkspaceSchemaObjectReference(databaseName: database.name, objectName: object.name)
                        guard let value = values.first(where: { $0.reference == reference }) else { return object }
                        loaded.insert(reference)
                        return .init(name: object.name, kind: object.kind, columns: value.columns, comment: object.comment)
                    })
                }
                self.revision += 1
                self.snapshot = .init(revision: self.revision, databases: databases, loadedColumnObjects: loaded)
                self.errorMessage = nil; self.columnTask = nil; self.pendingColumns = []; self.isLoading = false
            } catch {
                guard let self, self.generation == token, self.columnID == id else { return }
                if !(error is CancellationError) { self.errorMessage = MobileConnectionFeedback.reading(error) }
                self.columnTask = nil; self.pendingColumns = []; self.isLoading = false
            }
        }
        await columnTask?.value
        return snapshot
    }

    private func publish(_ databases: [WorkspaceSchemaDatabase]) {
        revision += 1; snapshot = .init(revision: revision, databases: databases)
    }
}
