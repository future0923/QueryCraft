import Foundation
@testable import QueryCraftFeature

actor CatalogPhaseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

actor CatalogRequestRecorder {
    private var recordedRequests: [[WorkspaceSchemaObjectReference]] = []

    func record(_ objects: [WorkspaceSchemaObjectReference]) {
        recordedRequests.append(objects)
    }

    func requests() -> [[WorkspaceSchemaObjectReference]] {
        recordedRequests
    }
}

struct PhasedCatalogSessionFactory: WorkspaceSessionFactory {
    let databases: [String]
    let objectCatalog: [WorkspaceSchemaDatabase]
    let columnsByObject: [WorkspaceSchemaObjectReference: [WorkspaceSchemaColumn]]
    let columnGate: CatalogPhaseGate?
    let failsColumnLoad: Bool
    let recorder: CatalogRequestRecorder

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession {
        InMemoryWorkspaceSession(databases: databases)
    }

    func makeSchemaCatalogSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> (any WorkspaceSession)? {
        PhasedCatalogWorkspaceSession(
            objectCatalog: objectCatalog,
            columnsByObject: columnsByObject,
            columnGate: columnGate,
            failsColumnLoad: failsColumnLoad,
            recorder: recorder
        )
    }
}

private actor PhasedCatalogWorkspaceSession: WorkspaceSession {
    private let objectCatalog: [WorkspaceSchemaDatabase]
    private let columnsByObject: [
        WorkspaceSchemaObjectReference: [WorkspaceSchemaColumn]
    ]
    private let columnGate: CatalogPhaseGate?
    private let failsColumnLoad: Bool
    private let recorder: CatalogRequestRecorder
    private var isConnected = false

    init(
        objectCatalog: [WorkspaceSchemaDatabase],
        columnsByObject: [
            WorkspaceSchemaObjectReference: [WorkspaceSchemaColumn]
        ],
        columnGate: CatalogPhaseGate?,
        failsColumnLoad: Bool,
        recorder: CatalogRequestRecorder
    ) {
        self.objectCatalog = objectCatalog
        self.columnsByObject = columnsByObject
        self.columnGate = columnGate
        self.failsColumnLoad = failsColumnLoad
        self.recorder = recorder
    }

    func connect() async throws {
        isConnected = true
    }

    func fetchDatabases() async throws -> [String] {
        objectCatalog.map(\.name)
    }

    func fetchSchemaObjectCatalog() async throws -> [WorkspaceSchemaDatabase] {
        guard isConnected else { throw WorkspaceSessionError.notConnected }
        return objectCatalog
    }

    func fetchSchemaColumns(
        for objects: [WorkspaceSchemaObjectReference]
    ) async throws -> [WorkspaceSchemaObjectColumns] {
        guard isConnected else { throw WorkspaceSessionError.notConnected }
        await recorder.record(objects)
        if let columnGate {
            await columnGate.wait()
        }
        try Task.checkCancellation()
        if failsColumnLoad {
            throw WorkspaceSessionError.metadataUnavailable(object: "columns")
        }
        return objects.map {
            WorkspaceSchemaObjectColumns(
                reference: $0,
                columns: columnsByObject[$0, default: []]
            )
        }
    }

    func fetchObjects(
        in database: String
    ) async throws -> [WorkspaceDatabaseObject] {
        []
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        throw WorkspaceSessionError.metadataUnavailable(object: object.name)
    }

    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] {
        []
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        throw WorkspaceSessionError.queryUnavailable
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        throw WorkspaceSessionError.queryUnavailable
    }

    func connectionID() async throws -> Int {
        throw WorkspaceSessionError.queryUnavailable
    }

    func executeReadOnlyQuery(
        _ sql: String,
        database: String?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        throw WorkspaceSessionError.queryUnavailable
    }

    func cancelQuery(connectionID: Int) async throws {
        throw WorkspaceSessionError.queryUnavailable
    }

    func close() async {
        isConnected = false
    }
}
