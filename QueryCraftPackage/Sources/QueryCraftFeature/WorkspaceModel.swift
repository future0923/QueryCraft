import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceModel {
    enum DatabaseRefreshResult: Equatable {
        case refreshed
        case cancelled
        case reconnectRequired
    }

    private(set) var workspaceID: UUID
    let profileID: ConnectionProfile.ID
    let safetyLock: WorkspaceSafetyLock
    private(set) var profileName = AppCopy.current.text("工作区", "Workspace")
    private(set) var databaseType = DatabaseType.mysql
    private(set) var sessionCapabilities = WorkspaceSessionCapabilities.standard
    private(set) var schemaEditingDescriptor =
        WorkspaceDatabaseSchemaEditingDescriptor.unavailable
    private(set) var connectionEndpoint = ""
    private(set) var connectionState = WorkspaceConnectionState.connecting
    private(set) var databases: [WorkspaceDatabase] = []
    private(set) var savedQueries: [SavedQuery] = []
    private(set) var savedQueryLoadErrorMessage: String?
    private(set) var recoverableDraftErrorMessage = ""
    var isShowingRecoverableDraftError = false
    private(set) var workspaceRestorationErrorMessage = ""
    var isShowingWorkspaceRestorationError = false
    private(set) var selectedObject: WorkspaceDatabaseObjectSelection?
    private(set) var queryDocuments: [WorkspaceQueryDocumentModel] = []
    private(set) var selectedQueryDocumentID: UUID?
    private(set) var databaseContextName: String?
    private(set) var availableSchemas: [String] = []
    private(set) var selectedSchema: String?
    private(set) var redisLogicalDatabases: [RedisLogicalDatabase] = []
    private(set) var redisKeys: [RedisKeyReference] = []
    private(set) var redisKeyTree: [RedisKeyTreeNode] = [] {
        didSet { redisKeyTreeRevision &+= 1 }
    }
    private(set) var redisKeyTreeRevision = 0
    private(set) var lastDeletedRedisKey: RedisKeyReference?
    private(set) var redisKeyDeletionRevision = 0
    private(set) var lastRenamedRedisKey: (
        old: RedisKeyReference,
        new: RedisKeyReference
    )?
    private(set) var redisKeyRenameRevision = 0
    private var redisHashFieldsByKey: [RedisKeyReference: [String]] = [:]
    private(set) var redisKeyScanCursor: UInt64 = 0
    private(set) var isRedisKeyScanComplete = true
    private(set) var isLoadingRedisKeys = false
    private(set) var isLoadingAllRedisKeys = false
    private(set) var redisKeyLoadDiscoveredCount = 0
    private(set) var redisKeyLoadErrorMessage: String?
    var redisSidebarSelection: RedisKeyReference?
    var isRedisKeyExactSearch = false
    var searchText = ""
    var showsElasticsearchSystemResources = false
    var isElasticsearchDataStreamGroupExpanded = true
    var isElasticsearchAliasGroupExpanded = true
    var isElasticsearchIndexGroupExpanded = true
    var sidebarMode = WorkspaceSidebarMode.items

    private let repository: any ConnectionProfileRepository
    private let savedQueryRepository: any SavedQueryRepository
    private let recoverableDraftRepository: any RecoverableDraftRepository
    private let initialRestorationState: WorkspaceRestorationState?
    private let recoversUnassignedDrafts: Bool
    private let excludedRecoverableDraftIDs: Set<UUID>
    private let recoverableDraftSaveDelay: Duration
    private let credentialStore: any CredentialStore
    private let workspacePassword: String?
    private let sessionFactory: any WorkspaceSessionFactory
    private let schemaCatalogCoordinator: WorkspaceSchemaCatalogCoordinator
    private let sessionOperationGate = WorkspaceSessionOperationGate()
    private var session: (any WorkspaceSession)?
    private var schemaEditingProvider: (any DatabaseSchemaEditingProvider)?
    private var dataSession: (any WorkspaceSession)?
    private var dataCountSession: (any WorkspaceSession)?
    private var sessionConfiguration: DatabaseConnectionConfiguration?
    private var dataLoadID: UUID?
    private var dataLoadSelection: WorkspaceDatabaseObjectSelection?
    @ObservationIgnored private var dataReplacementLoadID: UUID?
    @ObservationIgnored private var dataReplacementRowStore:
        WorkspaceDatabaseDataRowStore?
    private var dataCountLoadID: UUID?
    private var dataCountLoadSelection: WorkspaceDatabaseObjectSelection?
    private var objectLoadQueue: [String] = []
    private var objectLoadGeneration = 0
    private var objectRequestGenerations: [String: Int] = [:]
    private var savedQueryRevision = 0
    private var savedQueryMutationIDs: Set<SavedQuery.ID> = []
    private var didRecoverDrafts = false
    private var isRecoveringDrafts = false
    private var recoverableDraftGenerations: [UUID: Int] = [:]
    private var recoverableDraftCreatedAt: [UUID: Date] = [:]
    private var restoredSelectedObject: WorkspaceDatabaseObjectSelection?
    private var nextQueryDocumentNumber = 1
    private var nextRedisCommandDocumentNumber = 1
    private var nextElasticsearchRequestDocumentNumber = 1
    private var objectDetailsStates: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseObjectDetailsState
    ] = [:]
    private var objectIndexesStates: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseIndexesState
    ] = [:]
    private var objectDataStates: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseDataState
    ] = [:]
    private var objectDataOffsets: [
        WorkspaceDatabaseObjectSelection: Int
    ] = [:]
    private var objectDataLimits: [
        WorkspaceDatabaseObjectSelection: Int
    ] = [:]
    private var objectDataSorts: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseDataSort
    ] = [:]
    private var objectDataFilters: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseDataFilter
    ] = [:]
    private var objectDataCountStates: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseDataCountState
    ] = [:]
    private var objectDataCountFilters: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseDataFilter
    ] = [:]
    @ObservationIgnored private var objectLoadingTask: Task<Void, Never>?
    @ObservationIgnored private var elasticsearchCompletionFieldLoads: [
        WorkspaceDatabaseObjectSelection: (
            id: UUID,
            task: Task<[String], Never>
        )
    ] = [:]
    @ObservationIgnored private var dataCountTask: Task<Void, Never>?
    @ObservationIgnored private var dataCleanupTasks: [
        UUID: Task<Void, Never>
    ] = [:]
    @ObservationIgnored private var recoverableDraftTasks: [
        UUID: Task<Void, Never>
    ] = [:]
    @ObservationIgnored private var workspaceMoveTask: Task<Void, Never>?
    @ObservationIgnored private let redisKeyTreeBuilder = RedisKeyTreeBuilder()
    @ObservationIgnored private let redisKeyScanLoader = RedisKeyScanLoader()
    @ObservationIgnored private var redisKeyLoadTask: Task<Void, Never>?
    private var redisKeyLoadGeneration = 0
    private var activeRedisKeySearch = RedisKeySearchRequest(
        text: "",
        mode: .contains
    )
    @ObservationIgnored private var redisTreeBuildGeneration = 0
    private var workspaceMoveGeneration = 0

    var visibleDatabases: [WorkspaceDatabase] {
        databases.filter { database in
            guard !searchText.isEmpty else { return true }

            if database.name.localizedCaseInsensitiveContains(searchText) {
                return true
            }
            if savedQueries(in: database.name).contains(
                where: savedQueryMatchesSearch
            ) {
                return true
            }
            guard case let .loaded(objects) = database.objectsState else {
                return false
            }
            return objects.contains {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var visibleGeneralSavedQueries: [SavedQuery] {
        savedQueries.filter {
            $0.defaultDatabase == nil && savedQueryMatchesSearch($0)
        }
    }

    var visibleSavedQueries: [SavedQuery] {
        savedQueries.filter(savedQueryMatchesSearch)
    }

    var availableDatabaseNames: [String] {
        var names = Set(databases.map(\.name))
        if let databaseContextName {
            names.insert(databaseContextName)
        }
        return names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var elasticsearchOrdinaryIndexNames: [String] {
        guard databaseType == .elasticsearch,
              let database = currentDatabase,
              case let .loaded(objects) = database.objectsState else { return [] }
        return objects.lazy
            .filter { object in
                object.kind == .elasticsearchIndex
                    && !object.name.hasPrefix(".ds-")
                    && (self.showsElasticsearchSystemResources || !object.name.hasPrefix("."))
            }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var availableDatabaseKeyCounts: [String: Int] {
        guard databaseType == .redis else { return [:] }
        return redisLogicalDatabases.reduce(into: [:]) { counts, database in
            if let keyCount = database.keyCount {
                counts[database.name] = keyCount
            }
        }
    }

    var currentDatabase: WorkspaceDatabase? {
        guard let databaseContextName else { return nil }
        return databases.first { $0.name == databaseContextName }
    }

    var visibleUnavailableSavedQueries: [SavedQuery] {
        let availableDatabaseNames = Set(databases.map(\.name))
        return savedQueries.filter {
            guard let defaultDatabase = $0.defaultDatabase else {
                return false
            }
            return !availableDatabaseNames.contains(defaultDatabase)
                && savedQueryMatchesSearch($0)
        }
    }

    var selectedObjectDetailsState: WorkspaceDatabaseObjectDetailsState {
        guard let selectedObject else { return .notLoaded }
        return objectDetailsStates[selectedObject] ?? .notLoaded
    }

    var selectedObjectDataState: WorkspaceDatabaseDataState {
        guard let selectedObject else { return .notLoaded }
        return objectDataStates[selectedObject] ?? .notLoaded
    }

    var selectedObjectIndexesState: WorkspaceDatabaseIndexesState {
        guard let selectedObject else { return .notLoaded }
        return objectIndexesStates[selectedObject] ?? .notLoaded
    }

    var selectedObjectDataCountState: WorkspaceDatabaseDataCountState {
        guard let selectedObject else { return .notLoaded }
        return objectDataCountStates[selectedObject] ?? .notLoaded
    }

    func updateDataCell(
        _ update: WorkspaceDatabaseDataCellUpdate
    ) async throws {
        guard !safetyLock.isEnabled else {
            throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled
        }
        guard
            selectedObject == update.selection,
            update.selection.kind == .table,
            connectionState == .connected,
            let configuration = sessionConfiguration
        else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }

        let updateSession = await sessionFactory.makeSession(
            configuration: configuration
        )
        let affectedRows: Int
        do {
            try await updateSession.connect()
            try Task.checkCancellation()
            guard
                selectedObject == update.selection,
                !safetyLock.isEnabled,
                connectionState == .connected
            else {
                throw WorkspaceDatabaseDataCellEditError.editingContextChanged
            }
            affectedRows = try await updateSession.updateDataCell(update)
            await updateSession.close()
        } catch {
            await updateSession.close()
            throw error
        }
        switch affectedRows {
        case 1:
            return
        case 0:
            throw WorkspaceDatabaseDataCellEditError.rowChanged
        default:
            throw WorkspaceDatabaseDataCellEditError
                .unexpectedAffectedRows(affectedRows)
        }
    }

    func updateDataCells(
        _ updates: [WorkspaceDatabaseDataCellUpdate]
    ) async throws {
        guard
            let selection = updates.first?.selection,
            updates.allSatisfy({ $0.selection == selection })
        else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }
        guard !safetyLock.isEnabled else {
            throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled
        }
        guard
            selectedObject == selection,
            selection.kind == .table,
            connectionState == .connected,
            let configuration = sessionConfiguration
        else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }

        let updateSession = await sessionFactory.makeSession(
            configuration: configuration
        )
        do {
            try await updateSession.connect()
            try Task.checkCancellation()
            guard
                selectedObject == selection,
                !safetyLock.isEnabled,
                connectionState == .connected
            else {
                throw WorkspaceDatabaseDataCellEditError.editingContextChanged
            }
            try await updateSession.updateDataCells(updates)
            await updateSession.close()
        } catch {
            await updateSession.close()
            throw error
        }
    }

    func insertDataRow(
        _ insert: WorkspaceDatabaseDataRowInsert
    ) async throws {
        try await insertDataRows([insert])
    }

    func insertDataRows(
        _ inserts: [WorkspaceDatabaseDataRowInsert]
    ) async throws {
        guard
            let selection = inserts.first?.selection,
            inserts.allSatisfy({ $0.selection == selection })
        else {
            throw WorkspaceDatabaseDataRowInsertError.editingContextChanged
        }
        guard !safetyLock.isEnabled else {
            throw WorkspaceDatabaseDataRowInsertError.safetyLockEnabled
        }
        guard
            selectedObject == selection,
            selection.kind == .table,
            connectionState == .connected,
            let configuration = sessionConfiguration
        else {
            throw WorkspaceDatabaseDataRowInsertError.editingContextChanged
        }

        let insertSession = await sessionFactory.makeSession(
            configuration: configuration
        )
        do {
            try await insertSession.connect()
            try Task.checkCancellation()
            guard
                selectedObject == selection,
                !safetyLock.isEnabled,
                connectionState == .connected
            else {
                throw WorkspaceDatabaseDataRowInsertError.editingContextChanged
            }
            try await insertSession.insertDataRows(inserts)
            await insertSession.close()
        } catch {
            await insertSession.close()
            throw error
        }
    }

    func deleteDataRow(
        _ delete: WorkspaceDatabaseDataRowDelete
    ) async throws {
        guard !safetyLock.isEnabled else {
            throw WorkspaceDatabaseDataRowDeleteError.safetyLockEnabled
        }
        guard
            selectedObject == delete.selection,
            delete.selection.kind == .table,
            connectionState == .connected,
            let configuration = sessionConfiguration
        else {
            throw WorkspaceDatabaseDataRowDeleteError.editingContextChanged
        }

        let deleteSession = await sessionFactory.makeSession(
            configuration: configuration
        )
        let affectedRows: Int
        do {
            try await deleteSession.connect()
            try Task.checkCancellation()
            guard
                selectedObject == delete.selection,
                !safetyLock.isEnabled,
                connectionState == .connected
            else {
                throw WorkspaceDatabaseDataRowDeleteError.editingContextChanged
            }
            affectedRows = try await deleteSession.deleteDataRow(delete)
            await deleteSession.close()
        } catch {
            await deleteSession.close()
            throw error
        }
        switch affectedRows {
        case 1:
            return
        case 0:
            throw WorkspaceDatabaseDataRowDeleteError.rowChanged
        default:
            throw WorkspaceDatabaseDataRowDeleteError
                .unexpectedAffectedRows(affectedRows)
        }
    }

    func applyDataChanges(
        _ changes: WorkspaceDatabaseDataChangeSet
    ) async throws {
        try await applyDataChanges(changes, requiredSelection: selectedObject)
    }

    func fetchQueryResultDetails(
        for selection: WorkspaceDatabaseObjectSelection,
        configuration: DatabaseConnectionConfiguration
    ) async throws -> WorkspaceDatabaseObjectDetails {
        let metadataSession = await sessionFactory.makeSession(
            configuration: configuration
        )
        do {
            try await metadataSession.connect()
            try Task.checkCancellation()
            let objects = try await metadataSession.fetchObjects(
                in: selection.databaseName
            )
            guard objects.contains(where: {
                $0.name == selection.objectName && $0.kind == .table
            }) else {
                throw WorkspaceDatabaseDataCellEditError.tableRequired
            }
            let details = try await metadataSession.fetchDetails(
                for: selection.object,
                in: selection.databaseName
            )
            await metadataSession.close()
            return details
        } catch {
            await metadataSession.close()
            throw error
        }
    }

    func applyQueryResultDataChanges(
        _ changes: WorkspaceDatabaseDataChangeSet,
        configuration: DatabaseConnectionConfiguration
    ) async throws {
        try await applyDataChanges(
            changes,
            requiredSelection: nil,
            configurationOverride: configuration
        )
    }

    private func applyDataChanges(
        _ changes: WorkspaceDatabaseDataChangeSet,
        requiredSelection: WorkspaceDatabaseObjectSelection?,
        configurationOverride: DatabaseConnectionConfiguration? = nil
    ) async throws {
        guard
            !changes.isEmpty,
            changes.hasConsistentSelection,
            let selection = changes.selection
        else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }
        guard !safetyLock.isEnabled else {
            throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled
        }
        guard
            requiredSelection == nil || requiredSelection == selection,
            selection.kind == .table,
            let configuration = configurationOverride ?? sessionConfiguration,
            configurationOverride != nil || connectionState == .connected
        else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }

        let changeSession = await sessionFactory.makeSession(
            configuration: configuration
        )
        do {
            try await changeSession.connect()
            try Task.checkCancellation()
            guard
                configurationOverride != nil
                    || sessionConfiguration == configuration,
                requiredSelection == nil || selectedObject == selection,
                !safetyLock.isEnabled,
                configurationOverride != nil || connectionState == .connected
            else {
                throw WorkspaceDatabaseDataCellEditError.editingContextChanged
            }
            try await changeSession.applyDataChanges(changes)
            await changeSession.close()
        } catch {
            await changeSession.close()
            throw error
        }
    }

    func applySchemaChanges(
        _ changes: WorkspaceDatabaseSchemaChangeSet
    ) async throws {
        let plan = try schemaExecutionPlan(for: changes)
        try await applySchemaExecutionPlan(plan)
    }

    func schemaExecutionPlan(
        for changes: WorkspaceDatabaseSchemaChangeSet
    ) throws -> WorkspaceDatabaseSchemaExecutionPlan {
        guard let schemaEditingProvider else {
            throw WorkspaceSessionError.queryUnavailable
        }
        return try schemaEditingProvider.makeExecutionPlan(for: changes)
    }

    func schemaExecutionPlan(
        for mutation: WorkspaceDatabaseTableMutation
    ) throws -> WorkspaceDatabaseSchemaExecutionPlan {
        guard let schemaEditingProvider else {
            throw WorkspaceSessionError.queryUnavailable
        }
        return try schemaEditingProvider.makeExecutionPlan(for: mutation)
    }

    func applySchemaExecutionPlan(
        _ plan: WorkspaceDatabaseSchemaExecutionPlan
    ) async throws {
        guard case let .changes(changes) = plan.source else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }
        guard !changes.isEmpty else { return }
        guard !safetyLock.isEnabled else {
            throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled
        }
        guard
            selectedObject == changes.selection,
            changes.selection.kind == .table,
            connectionState == .connected,
            let configuration = sessionConfiguration
        else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }

        let changeSession = await sessionFactory.makeSession(
            configuration: configuration
        )
        do {
            try await changeSession.connect()
            try Task.checkCancellation()
            guard
                selectedObject == changes.selection,
                !safetyLock.isEnabled,
                connectionState == .connected
            else {
                throw WorkspaceDatabaseDataCellEditError.editingContextChanged
            }
            try await changeSession.applySchemaExecutionPlan(plan)
            await changeSession.close()
        } catch {
            await changeSession.close()
            throw error
        }
    }

    func applyTableMutation(
        _ mutation: WorkspaceDatabaseTableMutation
    ) async throws {
        guard !safetyLock.isEnabled else {
            throw WorkspaceDatabaseTableMutationError.safetyLockEnabled
        }
        let plan = try schemaExecutionPlan(for: mutation)
        try await applyTableMutation(plan)
    }

    func applyTableMutation(
        _ plan: WorkspaceDatabaseSchemaExecutionPlan
    ) async throws {
        guard case let .tableMutation(mutation) = plan.source else {
            throw WorkspaceDatabaseTableMutationError.contextChanged
        }
        guard !safetyLock.isEnabled else {
            throw WorkspaceDatabaseTableMutationError.safetyLockEnabled
        }
        guard
            connectionState == .connected,
            databaseContextName == mutation.databaseName,
            mutation.sourceSelection?.kind != .view,
            let configuration = sessionConfiguration
        else {
            throw WorkspaceDatabaseTableMutationError.contextChanged
        }

        let changeSession = await sessionFactory.makeSession(
            configuration: configuration
        )
        do {
            try await changeSession.connect()
            try Task.checkCancellation()
            guard
                connectionState == .connected,
                databaseContextName == mutation.databaseName,
                !safetyLock.isEnabled
            else {
                throw WorkspaceDatabaseTableMutationError.contextChanged
            }
            try await changeSession.applySchemaExecutionPlan(plan)
            await changeSession.close()
            _ = await refreshObjects(in: mutation.databaseName)
        } catch {
            await changeSession.close()
            throw error
        }
    }

    func dataExportAllRowsProvider(
        for selection: WorkspaceDatabaseObjectSelection,
        sort: WorkspaceDatabaseDataSort,
        filter: WorkspaceDatabaseDataFilter = .empty
    ) -> WorkspaceDataExportAllRowsProvider? {
        guard
            selectedObject == selection,
            let configuration = sessionConfiguration,
            session != nil
        else {
            return nil
        }
        let estimatedRowCount: Int?
        if case let .loaded(count) =
            objectDataCountStates[selection] ?? .notLoaded,
            objectDataCountFilters[selection] == filter
        {
            estimatedRowCount = count
        } else {
            estimatedRowCount = nil
        }
        let sessionFactory = sessionFactory
        return WorkspaceDataExportAllRowsProvider(
            estimatedRowCount: estimatedRowCount,
            makeSource: {
                WorkspaceTableDataExportRowSource(
                    sessionFactory: sessionFactory,
                    configuration: configuration,
                    selection: selection,
                    sort: sort,
                    filter: filter
                )
            }
        )
    }

    var sidebarSelection: WorkspaceDatabaseObjectSelection? {
        get { selectedObject }
        set {
            guard let cleanup = updateSidebarSelection(newValue) else { return }
            Task { [weak self] in
                await self?.stopDataWork(
                    for: cleanup.selection,
                    reason: cleanup.reason
                )
            }
        }
    }

    var schemaCatalog: WorkspaceSchemaCatalogSnapshot {
        schemaCatalogCoordinator.snapshot
    }

    var workspaceRestorationState: WorkspaceRestorationState? {
        initialRestorationState
    }

    init(
        profileID: ConnectionProfile.ID,
        workspaceID: UUID = UUID(),
        repository: any ConnectionProfileRepository,
        savedQueryRepository: any SavedQueryRepository =
            InMemorySavedQueryRepository(),
        recoverableDraftRepository: any RecoverableDraftRepository =
            InMemoryRecoverableDraftRepository(),
        restorationState: WorkspaceRestorationState? = nil,
        recoverableDraftSaveDelay: Duration = .milliseconds(500),
        databaseContextName: String? = nil,
        safetyLock: WorkspaceSafetyLock? = nil,
        recoversUnassignedDrafts: Bool = true,
        excludedRecoverableDraftIDs: Set<UUID> = [],
        credentialStore: any CredentialStore,
        workspacePassword: String? = nil,
        sessionFactory: any WorkspaceSessionFactory
    ) {
        self.workspaceID = workspaceID
        self.profileID = profileID
        self.repository = repository
        self.savedQueryRepository = savedQueryRepository
        self.recoverableDraftRepository = recoverableDraftRepository
        initialRestorationState = restorationState
        self.recoversUnassignedDrafts = recoversUnassignedDrafts
        self.excludedRecoverableDraftIDs = excludedRecoverableDraftIDs
        restoredSelectedObject = restorationState?.selectedDatabaseContext
            .selectedObject
        self.recoverableDraftSaveDelay = recoverableDraftSaveDelay
        self.databaseContextName = databaseContextName
        self.safetyLock = safetyLock ?? WorkspaceSafetyLock()
        self.credentialStore = credentialStore
        self.workspacePassword = workspacePassword
        self.sessionFactory = sessionFactory
        schemaCatalogCoordinator = WorkspaceSchemaCatalogCoordinator(
            sessionFactory: sessionFactory
        )
    }

    func run(
        didConnect: @escaping @MainActor () async -> Void = {}
    ) async {
        guard let activeSession = await connect(
            didRecoverDocuments: didConnect
        ) else {
            return
        }
        await didConnect()

        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(86_400))
            }
        } catch is CancellationError {
            // The window closed or a reconnect replaced this task.
        } catch {
            // Sleeping does not otherwise fail.
        }

        await close(activeSession)
    }

    func prepareForConnectionAttempt() {
        connectionState = .connecting
        cancelObjectLoads()
    }

    @discardableResult
    func connect(
        didRecoverDocuments: @escaping @MainActor () async -> Void = {}
    ) async -> (any WorkspaceSession)? {
        connectionState = .connecting
        await reloadSavedQueries()
        var connectingSession: (any WorkspaceSession)?

        do {
            guard let profile = try await repository.fetch(id: profileID) else {
                throw WorkspaceError.profileNotFound
            }
            profileName = profile.name
            databaseType = profile.databaseType
            connectionEndpoint = "\(profile.username)@\(profile.host):\(profile.port)"
            if databaseContextName == nil {
                databaseContextName = profile.defaultDatabase
            }

            let password: String? = if let workspacePassword {
                workspacePassword
            } else if profile.storesCredential {
                try await credentialStore.password(for: profile.id)
            } else {
                nil
            }
            let configuration = DatabaseConnectionConfiguration(
                databaseType: profile.databaseType,
                databaseProduct: profile.databaseProduct,
                host: profile.host,
                port: profile.port,
                authentication: profile.authentication(secret: password),
                database: databaseContextName,
                tlsMode: profile.tlsMode
            )
            if profile.databaseType != .redis,
               await recoverDraftsIfNeeded(configuration: configuration)
            {
                await didRecoverDocuments()
            }
            let newSession = await sessionFactory.makeSession(
                configuration: configuration
            )
            connectingSession = newSession
            session = newSession

            try await newSession.connect()
            try Task.checkCancellation()
            let editingProvider: (any DatabaseSchemaEditingProvider)?
            let logicalDatabases: [RedisLogicalDatabase]
            let names: [String]
            if let redisSession = newSession as? any RedisWorkspaceSession {
                editingProvider = nil
                logicalDatabases = try await redisSession
                    .fetchRedisLogicalDatabases()
                names = logicalDatabases.map(\.name)
            } else {
                editingProvider = await newSession.schemaEditingProvider()
                logicalDatabases = []
                names = try await newSession.fetchDatabases()
            }
            try Task.checkCancellation()
            adoptImplicitDatabaseContextIfNeeded(from: names)
            let schemaNames: [String]
            if profile.databaseType == .postgresql,
               let databaseName = databaseContextName ?? names.first
            {
                schemaNames = (try? await newSession.fetchSchemas(
                    in: databaseName
                )) ?? []
            } else {
                schemaNames = []
            }
            try Task.checkCancellation()
            guard session === newSession else {
                await newSession.close()
                return nil
            }

            databases = makeDatabases(from: names)
            redisLogicalDatabases = logicalDatabases
            replaceAvailableSchemas(schemaNames)
            schemaEditingProvider = editingProvider
            sessionCapabilities = newSession.resolvedCapabilities
            schemaEditingDescriptor = editingProvider?.descriptor ?? .unavailable
            schemaCatalogCoordinator.seedDatabases(names)
            sessionConfiguration = configuration
            for document in queryDocuments {
                await document.replaceConnectionConfiguration(
                    configuration,
                    availableDatabases: names
                )
            }
            objectDetailsStates.removeAll()
            objectIndexesStates.removeAll()
            objectDataStates.removeAll()
            objectDataOffsets.removeAll()
            objectDataLimits.removeAll()
            objectDataSorts.removeAll()
            objectDataCountStates.removeAll()
            dataLoadID = nil
            dataLoadSelection = nil
            clearDataReplacement()
            dataCountLoadID = nil
            dataCountLoadSelection = nil
            connectionState = .connected
            await restoreSelectedObjectIfAvailable()
            if profile.databaseType == .redis {
                await loadRedisKeys(reset: true)
            } else {
                _ = await schemaCatalogCoordinator.startRefresh(
                    configuration: configuration
                )
            }
            return newSession
        } catch is CancellationError {
            if let connectingSession {
                await close(connectingSession)
            }
            return nil
        } catch {
            let failedSessionWasActive = connectingSession.map {
                self.session === $0
            } ?? false
            if let connectingSession {
                await close(connectingSession)
            }
            guard connectingSession == nil || failedSessionWasActive else {
                return nil
            }
            connectionState = .failed(error.localizedDescription)
            return nil
        }
    }

    func disconnect() async {
        guard let session else { return }
        await close(session)
    }

    @discardableResult
    func adoptDatabaseContext(_ databaseName: String) async -> Bool {
        guard availableDatabaseNames.contains(databaseName) else { return false }
        databaseContextName = databaseName
        guard let configuration = sessionConfiguration else { return false }
        let updatedConfiguration = configuration.selecting(
            database: databaseName
        )
        let requiresSessionReconnect = databaseType == .redis
            ? false
            : configuration != updatedConfiguration
        sessionConfiguration = updatedConfiguration
        for document in queryDocuments {
            await document.replaceConnectionConfiguration(
                updatedConfiguration,
                availableDatabases: availableDatabaseNames
            )
        }
        if databaseType == .redis {
            searchText = ""
            activeRedisKeySearch = RedisKeySearchRequest(
                text: "",
                mode: .contains
            )
            redisSidebarSelection = nil
            await loadRedisKeys(reset: true)
        } else if !requiresSessionReconnect {
            _ = await schemaCatalogCoordinator.startRefresh(
                configuration: updatedConfiguration
            )
        }
        return requiresSessionReconnect
    }

    func selectSchema(_ schema: String) {
        guard databaseType == .postgresql,
              availableSchemas.contains(schema)
        else { return }
        selectedSchema = schema
    }

    func makeSibling(databaseName: String) -> WorkspaceModel {
        WorkspaceModel(
            profileID: profileID,
            workspaceID: workspaceID,
            repository: repository,
            savedQueryRepository: savedQueryRepository,
            recoverableDraftRepository: recoverableDraftRepository,
            recoverableDraftSaveDelay: recoverableDraftSaveDelay,
            databaseContextName: databaseName,
            safetyLock: safetyLock,
            recoversUnassignedDrafts: false,
            excludedRecoverableDraftIDs: [],
            credentialStore: credentialStore,
            workspacePassword: workspacePassword,
            sessionFactory: sessionFactory
        )
    }

    func moveToWorkspace(_ workspaceID: UUID) async {
        await startMovingToWorkspace(workspaceID).value
    }

    func startMovingToWorkspace(
        _ workspaceID: UUID
    ) -> Task<Void, Never> {
        workspaceMoveGeneration += 1
        let moveGeneration = workspaceMoveGeneration
        workspaceMoveTask?.cancel()

        let tasks = Array(recoverableDraftTasks.values)
        for task in tasks {
            task.cancel()
        }
        recoverableDraftTasks.removeAll()
        self.workspaceID = workspaceID

        var dirtyDocumentGenerations: [(UUID, Int)] = []
        for document in queryDocuments where document.isDirty {
            recoverableDraftGenerations[document.id, default: 0] += 1
            let generation = recoverableDraftGenerations[document.id, default: 0]
            dirtyDocumentGenerations.append((document.id, generation))
        }

        let moveTask = Task { @MainActor [weak self] in
            for task in tasks {
                await task.value
            }
            guard let self,
                  self.workspaceMoveGeneration == moveGeneration,
                  !Task.isCancelled
            else {
                return
            }
            for (documentID, generation) in dirtyDocumentGenerations {
                guard !Task.isCancelled else { return }
                await self.persistRecoverableDraft(
                    for: documentID,
                    generation: generation
                )
            }
            guard self.workspaceMoveGeneration == moveGeneration else {
                return
            }
            self.workspaceMoveTask = nil
        }
        workspaceMoveTask = moveTask
        return moveTask
    }

    @discardableResult
    func requestObjects(in databaseName: String) -> Task<Void, Never>? {
        guard
            session != nil,
            connectionState == .connected,
            let index = databases.firstIndex(where: { $0.name == databaseName })
        else {
            return objectLoadingTask
        }

        switch databases[index].objectsState {
        case .notLoaded, .failed:
            databases[index].objectsState = .queued
        case .queued, .loading, .loaded:
            return objectLoadingTask
        }

        if !objectLoadQueue.contains(databaseName) {
            objectLoadQueue.append(databaseName)
        }
        startObjectLoaderIfNeeded()
        return objectLoadingTask
    }

    func selectObject(_ selection: WorkspaceDatabaseObjectSelection) async {
        if let cleanup = updateSidebarSelection(selection) {
            await stopDataWork(
                for: cleanup.selection,
                reason: cleanup.reason
            )
        }
    }

    @discardableResult
    func createQueryDocument() -> WorkspaceQueryDocumentModel? {
        guard
            databaseType != .redis,
            databaseType != .elasticsearch,
            connectionState == .connected,
            let sessionConfiguration
        else {
            return nil
        }
        restoredSelectedObject = nil
        let previousObject = selectedObject
        let document = WorkspaceQueryDocumentModel(
            title: AppCopy.current.text(
                "查询 \(nextQueryDocumentNumber)",
                "Query \(nextQueryDocumentNumber)"
            ),
            configuration: sessionConfiguration,
            sessionFactory: sessionFactory,
            recoverableContentDidChange: recoverableContentDidChange
        )
        nextQueryDocumentNumber += 1
        queryDocuments.append(document)
        if previousObject != nil {
            selectedObject = nil
        }
        selectedQueryDocumentID = document.id
        if let previousObject {
            scheduleDataCleanup(for: previousObject, reason: .leftDataTab)
        }
        return document
    }

    func createRedisCommandDocument() -> WorkspaceRedisCommandDocumentModel? {
        guard databaseType == .redis, connectionState == .connected else {
            return nil
        }
        let number = nextRedisCommandDocumentNumber
        nextRedisCommandDocumentNumber += 1
        return WorkspaceRedisCommandDocumentModel(
            title: AppCopy.current.text(
                "Command \(number)",
                "Command \(number)"
            ),
            databaseIndex: { [weak self] in
                self?.currentRedisDatabaseIndex ?? 0
            },
            availableKeys: { [weak self] in
                self?.redisKeys ?? []
            },
            availableHashFields: { [weak self] reference in
                self?.redisHashFieldsByKey[reference] ?? []
            },
            isSafetyLockEnabled: { [weak self] in
                self?.safetyLock.isEnabled ?? true
            },
            loadSuggestions: { [weak self] request in
                guard let self else { throw RedisWorkspaceError.unavailable }
                let expectedType: RedisKeyType = switch request.domain {
                case .hashField: .hash
                case .setMember: .set
                case .sortedSetMember: .sortedSet
                }
                let unresolved = RedisKeyReference(
                    databaseIndex: request.databaseIndex,
                    name: request.key
                )
                let resolved = try await self.resolveRedisKeyTypes([unresolved])
                    .first
                guard resolved?.type == expectedType else { return [] }
                let result = try await self.executeRedisCommand(
                    request.invocation,
                    databaseIndex: request.databaseIndex
                )
                return try request.candidates(from: result.reply)
            },
            executeCommand: { [weak self] invocation, databaseIndex in
                guard let self else { throw RedisWorkspaceError.unavailable }
                return try await self.executeRedisCommand(
                    invocation,
                    databaseIndex: databaseIndex
                )
            }
        )
    }

    func createElasticsearchRequestDocument()
        -> WorkspaceElasticsearchRequestDocumentModel?
    {
        guard databaseType == .elasticsearch,
              connectionState == .connected
        else { return nil }
        let number = nextElasticsearchRequestDocumentNumber
        nextElasticsearchRequestDocumentNumber += 1
        return makeElasticsearchRequestDocument(
            id: UUID(),
            title: AppCopy.current.text(
                "请求 \(number)",
                "Request \(number)"
            ),
            source: "GET /_cluster/health",
            resultRowLimit: .rows1_000,
            savedQueryID: nil,
            persistedSource: ""
        )
    }

    func restoreElasticsearchRequestDocuments(
        _ states: [WorkspaceElasticsearchRequestRestorationState]
    ) -> [WorkspaceElasticsearchRequestDocumentModel] {
        guard databaseType == .elasticsearch,
              connectionState == .connected
        else { return [] }
        nextElasticsearchRequestDocumentNumber = max(
            nextElasticsearchRequestDocumentNumber,
            states.count + 1
        )
        return states.map { state in
            makeElasticsearchRequestDocument(
                id: state.id,
                title: state.title,
                source: state.source,
                resultRowLimit: state.resultRowLimit,
                savedQueryID: state.savedQueryID,
                persistedSource: state.persistedSource ?? ""
            )
        }
    }

    private func makeElasticsearchRequestDocument(
        id: UUID,
        title: String,
        source: String,
        resultRowLimit: QueryResultRowLimit,
        savedQueryID: SavedQuery.ID?,
        persistedSource: String
    ) -> WorkspaceElasticsearchRequestDocumentModel {
        let document = WorkspaceElasticsearchRequestDocumentModel(
            id: id,
            title: title,
            source: source,
            savedQueryID: savedQueryID,
            persistedSource: persistedSource,
            completionFields: { [weak self] resourceName in
                guard let self else { return [] }
                return await self.elasticsearchCompletionFieldNames(
                    for: resourceName
                )
            },
            completionResources: { [weak self] in
                self?.elasticsearchCompletionResources() ?? []
            },
            execute: { [weak self] request in
                guard let self else {
                    throw WorkspaceSessionError.notConnected
                }
                return try await self.executeElasticsearchRequest(request)
            }
        )
        document.resultRowLimit = resultRowLimit
        document.authorize = { [weak self] requests in
            guard let self else { throw WorkspaceSessionError.notConnected }
            try self.authorizeElasticsearchRequests(requests)
        }
        document.batchDidWrite = { [weak self] in
            guard let self else { return }
            await self.didMutateElasticsearchMapping()
        }
        return document
    }

    func openElasticsearchSavedRequest(
        _ savedQueryID: SavedQuery.ID
    ) -> WorkspaceElasticsearchRequestDocumentModel? {
        guard databaseType == .elasticsearch,
              connectionState == .connected,
              let query = savedQueries.first(where: { $0.id == savedQueryID })
        else { return nil }
        return makeElasticsearchRequestDocument(
            id: UUID(),
            title: query.name,
            source: query.sql,
            resultRowLimit: .rows1_000,
            savedQueryID: query.id,
            persistedSource: query.sql
        )
    }

    @discardableResult
    func saveElasticsearchRequestDocument(
        _ document: WorkspaceElasticsearchRequestDocumentModel,
        name requestedName: String?,
        now: Date = .now
    ) async throws -> SavedQuery {
        guard databaseType == .elasticsearch else {
            throw WorkspaceSavedQueryError.documentNotFound
        }
        guard document.beginSaving() else {
            throw WorkspaceSavedQueryError.saveInProgress
        }
        let query: SavedQuery
        do {
            if let savedQueryID = document.savedQueryID {
                guard let existing = savedQueries.first(where: {
                    $0.id == savedQueryID
                }) else {
                    throw WorkspaceSavedQueryError.queryNotFound
                }
                query = SavedQuery(
                    id: existing.id,
                    connectionProfileID: profileID,
                    defaultDatabase: nil,
                    name: existing.name,
                    sql: document.source,
                    createdAt: existing.createdAt,
                    updatedAt: now
                )
                try await savedQueryRepository.update(query)
            } else {
                let name = requestedName?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""
                guard !name.isEmpty else {
                    throw WorkspaceSavedQueryError.missingName
                }
                query = SavedQuery(
                    id: UUID(),
                    connectionProfileID: profileID,
                    defaultDatabase: nil,
                    name: name,
                    sql: document.source,
                    createdAt: now,
                    updatedAt: now
                )
                try await savedQueryRepository.insert(query)
            }
        } catch {
            document.finishSaving(nil)
            throw error
        }
        savedQueryRevision += 1
        savedQueries.removeAll { $0.id == query.id }
        savedQueries.append(query)
        savedQueries.sort(by: Self.savedQueryDisplayOrder)
        savedQueryLoadErrorMessage = nil
        document.finishSaving(query)
        return query
    }

    private func elasticsearchCompletionFieldNames(
        for resourceName: String?
    ) async -> [String] {
        guard let resourceName,
              let selection = elasticsearchCompletionSelection(
                named: resourceName
              )
        else { return cachedElasticsearchCompletionFieldNames() }
        if case .loaded(let details) = objectDetailsStates[selection], elasticsearchDetailsRevisions[selection] == elasticsearchMutationRevision {
            return details.documentMappingFields?.map(\.path) ?? []
        }
        if let load = elasticsearchCompletionFieldLoads[selection] {
            return await load.task.value
        }
        guard let activeSession = session,
              connectionState == .connected
        else { return [] }

        let loadID = UUID()
        let mutationRevision = elasticsearchMutationRevision
        let task = Task<[String], Never> { @MainActor [weak self] in
            guard let self, self.session === activeSession else { return [] }
            do {
                let details = try await self.sessionOperationGate.run {
                    try await activeSession.fetchDetails(
                        for: selection.object,
                        in: selection.databaseName
                    )
                }
                try Task.checkCancellation()
                guard self.session === activeSession, self.elasticsearchMutationRevision == mutationRevision else { return [] }
                self.objectDetailsStates[selection] = .loaded(details)
                self.elasticsearchDetailsRevisions[selection] = mutationRevision
                return details.documentMappingFields?.map(\.path) ?? []
            } catch {
                return []
            }
        }
        elasticsearchCompletionFieldLoads[selection] = (loadID, task)
        let names = await task.value
        if elasticsearchCompletionFieldLoads[selection]?.id == loadID {
            elasticsearchCompletionFieldLoads[selection] = nil
        }
        return names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func cachedElasticsearchCompletionFieldNames() -> [String] {
        var names = Set<String>()
        for (selection, state) in objectDetailsStates where elasticsearchDetailsRevisions[selection] == elasticsearchMutationRevision {
            guard case .loaded(let details) = state else { continue }
            names.formUnion(details.documentMappingFields?.map(\.path) ?? [])
        }
        return names.sorted()
    }

    private func elasticsearchCompletionSelection(
        named resourceName: String
    ) -> WorkspaceDatabaseObjectSelection? {
        for database in databases {
            guard case .loaded(let objects) = database.objectsState,
                  let object = objects.first(where: { $0.name == resourceName })
            else { continue }
            return WorkspaceDatabaseObjectSelection(
                databaseName: database.name,
                objectName: object.name,
                kind: object.kind
            )
        }
        return nil
    }

    private func elasticsearchCompletionResources()
        -> [WorkspaceElasticsearchCompletionResource]
    {
        var resourcesByName: [String: WorkspaceDatabaseObjectKind] = [:]
        for database in databases {
            guard case .loaded(let objects) = database.objectsState else {
                continue
            }
            for object in objects {
                guard object.kind == .elasticsearchIndex
                        || object.kind == .elasticsearchAlias
                        || object.kind == .elasticsearchDataStream,
                      showsElasticsearchSystemResources
                        || (!object.name.hasPrefix(".")
                            && !object.name.hasPrefix(".ds-"))
                else { continue }
                resourcesByName[object.name] = object.kind
            }
        }
        return resourcesByName.map {
            WorkspaceElasticsearchCompletionResource(
                name: $0.key,
                kind: $0.value
            )
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func openSavedQueryDocument(
        _ savedQueryID: SavedQuery.ID
    ) -> WorkspaceSavedQueryOpenResult? {
        restoredSelectedObject = nil
        if let document = queryDocuments.first(where: {
            $0.savedQueryID == savedQueryID
        }) {
            let previousObject = activateQueryDocument(document.id)
            return WorkspaceSavedQueryOpenResult(
                document: document,
                isNewDocument: false,
                previousObject: previousObject
            )
        }

        guard connectionState == .connected,
              let sessionConfiguration,
              let savedQuery = savedQueries.first(where: {
                  $0.id == savedQueryID
              })
        else {
            return nil
        }

        let previousObject = selectedObject
        let document = WorkspaceQueryDocumentModel(
            title: savedQuery.name,
            configuration: sessionConfiguration,
            sessionFactory: sessionFactory,
            savedQuery: savedQuery,
            recoverableContentDidChange: recoverableContentDidChange
        )
        queryDocuments.append(document)
        if previousObject != nil {
            selectedObject = nil
        }
        selectedQueryDocumentID = document.id
        if let previousObject {
            scheduleDataCleanup(for: previousObject, reason: .leftDataTab)
        }
        return WorkspaceSavedQueryOpenResult(
            document: document,
            isNewDocument: true,
            previousObject: nil
        )
    }

    func saveQueryDocument(
        _ documentID: UUID,
        name requestedName: String? = nil,
        now: Date = .now
    ) async throws -> SavedQuery {
        guard let document = queryDocuments.first(where: {
            $0.id == documentID
        }) else {
            throw WorkspaceSavedQueryError.documentNotFound
        }
        if let savedQueryID = document.savedQueryID,
           savedQueryMutationIDs.contains(savedQueryID)
        {
            throw WorkspaceSavedQueryError.operationInProgress
        }
        guard document.beginSaving() else {
            throw WorkspaceSavedQueryError.saveInProgress
        }

        let query: SavedQuery
        do {
            if let savedQueryID = document.savedQueryID {
                guard let existing = savedQueries.first(where: {
                    $0.id == savedQueryID
                }) else {
                    throw WorkspaceSavedQueryError.queryNotFound
                }
                query = SavedQuery(
                    id: existing.id,
                    connectionProfileID: profileID,
                    defaultDatabase: document.databaseName,
                    name: existing.name,
                    sql: document.sql,
                    createdAt: existing.createdAt,
                    updatedAt: now
                )
                try await savedQueryRepository.update(query)
            } else {
                let name = requestedName?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else {
                    throw WorkspaceSavedQueryError.missingName
                }
                query = SavedQuery(
                    id: UUID(),
                    connectionProfileID: profileID,
                    defaultDatabase: document.databaseName,
                    name: name,
                    sql: document.sql,
                    createdAt: now,
                    updatedAt: now
                )
                try await savedQueryRepository.insert(query)
            }
        } catch {
            document.finishSaving(nil)
            throw error
        }

        savedQueryRevision += 1
        savedQueries.removeAll { $0.id == query.id }
        savedQueries.append(query)
        savedQueries.sort(by: Self.savedQueryDisplayOrder)
        savedQueryLoadErrorMessage = nil
        document.finishSaving(query)
        if document.isDirty {
            scheduleRecoverableDraftUpdate(for: document.id)
        } else {
            await discardRecoverableDraft(for: document.id)
        }
        return query
    }

    func savedQuery(id: SavedQuery.ID) -> SavedQuery? {
        savedQueries.first { $0.id == id }
    }

    func refreshSavedQueriesFromRepository() async
        -> [WorkspaceSavedQueryExternalChange]
    {
        let revision = savedQueryRevision
        do {
            let loadedQueries = try await savedQueryRepository.fetchAll(
                connectionProfileID: profileID
            )
            guard revision == savedQueryRevision else { return [] }
            savedQueries = loadedQueries
            savedQueryLoadErrorMessage = nil

            let queriesByID = Dictionary(
                uniqueKeysWithValues: loadedQueries.map { ($0.id, $0) }
            )
            var changes: [WorkspaceSavedQueryExternalChange] = []
            for document in queryDocuments {
                guard let savedQueryID = document.savedQueryID else { continue }
                guard let query = queriesByID[savedQueryID] else {
                    changes.append(.deleted(document: document))
                    continue
                }
                if document.reconcile(with: query) {
                    changes.append(.changed(document: document, query: query))
                } else if !document.isDirty {
                    await discardRecoverableDraft(for: document.id)
                }
            }
            return changes
        } catch is CancellationError {
            return []
        } catch {
            guard revision == savedQueryRevision else { return [] }
            savedQueryLoadErrorMessage = error.localizedDescription
            return []
        }
    }

    func reloadQueryDocument(
        _ document: WorkspaceQueryDocumentModel,
        from query: SavedQuery
    ) async {
        document.reload(from: query)
        await discardRecoverableDraft(for: document.id)
    }

    func ignoreQueryDocumentExternalChange(
        _ document: WorkspaceQueryDocumentModel,
        from query: SavedQuery
    ) async {
        guard queryDocuments.contains(where: { $0 === document }) else { return }
        document.ignoreExternalChange(from: query)
        if document.isDirty {
            scheduleRecoverableDraftUpdate(for: document.id)
        } else {
            await discardRecoverableDraft(for: document.id)
        }
    }

    func detachDeletedQueryDocument(
        _ document: WorkspaceQueryDocumentModel
    ) {
        guard queryDocuments.contains(where: { $0 === document }) else { return }
        document.detachFromSavedQuery()
        scheduleRecoverableDraftUpdate(for: document.id)
    }

    @discardableResult
    func renameSavedQuery(
        _ savedQueryID: SavedQuery.ID,
        name requestedName: String,
        now: Date = .now
    ) async throws -> SavedQuery {
        let name = requestedName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty else {
            throw WorkspaceSavedQueryError.missingName
        }
        let existing = try beginSavedQueryMutation(savedQueryID)
        defer { savedQueryMutationIDs.remove(savedQueryID) }
        guard name != existing.name else { return existing }

        let renamed = SavedQuery(
            id: existing.id,
            connectionProfileID: existing.connectionProfileID,
            defaultDatabase: existing.defaultDatabase,
            name: name,
            sql: existing.sql,
            createdAt: existing.createdAt,
            updatedAt: now
        )
        try await savedQueryRepository.update(renamed)
        finishSavedQueryMutation(renamed)
        return renamed
    }

    @discardableResult
    func duplicateSavedQuery(
        _ savedQueryID: SavedQuery.ID,
        now: Date = .now
    ) async throws -> SavedQuery {
        let existing = try beginSavedQueryMutation(savedQueryID)
        defer { savedQueryMutationIDs.remove(savedQueryID) }

        let duplicateID = UUID()
        var copyNumber = 1
        while true {
            let name = copyNumber == 1
                ? "\(existing.name) Copy"
                : "\(existing.name) Copy \(copyNumber)"
            let nameExists = savedQueries.contains {
                $0.connectionProfileID == existing.connectionProfileID
                    && $0.defaultDatabase == existing.defaultDatabase
                    && $0.name == name
            }
            if nameExists {
                copyNumber += 1
                continue
            }

            let duplicate = SavedQuery(
                id: duplicateID,
                connectionProfileID: existing.connectionProfileID,
                defaultDatabase: existing.defaultDatabase,
                name: name,
                sql: existing.sql,
                createdAt: now,
                updatedAt: now
            )
            do {
                try await savedQueryRepository.insert(duplicate)
                finishSavedQueryMutation(duplicate)
                return duplicate
            } catch SavedQueryRepositoryError.nameAlreadyExists {
                copyNumber += 1
            }
        }
    }

    @discardableResult
    func moveSavedQuery(
        _ savedQueryID: SavedQuery.ID,
        to defaultDatabase: String?,
        now: Date = .now
    ) async throws -> SavedQuery {
        let existing = try beginSavedQueryMutation(savedQueryID)
        defer { savedQueryMutationIDs.remove(savedQueryID) }
        guard defaultDatabase != existing.defaultDatabase else {
            return existing
        }

        let moved = SavedQuery(
            id: existing.id,
            connectionProfileID: existing.connectionProfileID,
            defaultDatabase: defaultDatabase,
            name: existing.name,
            sql: existing.sql,
            createdAt: existing.createdAt,
            updatedAt: now
        )
        try await savedQueryRepository.update(moved)
        finishSavedQueryMutation(moved)
        return moved
    }

    func deleteSavedQuery(_ savedQueryID: SavedQuery.ID) async throws {
        _ = try beginSavedQueryMutation(savedQueryID)
        defer { savedQueryMutationIDs.remove(savedQueryID) }

        try await savedQueryRepository.delete(id: savedQueryID)
        savedQueryRevision += 1
        savedQueries.removeAll { $0.id == savedQueryID }
        savedQueryLoadErrorMessage = nil
        let openDocument = queryDocuments.first {
            $0.savedQueryID == savedQueryID
        }
        openDocument?.detachFromSavedQuery()
        if let openDocument {
            scheduleRecoverableDraftUpdate(for: openDocument.id)
        }
    }

    func savedQueries(in databaseName: String) -> [SavedQuery] {
        savedQueries.filter { $0.defaultDatabase == databaseName }
    }

    func visibleSavedQueries(in databaseName: String) -> [SavedQuery] {
        savedQueries(in: databaseName).filter(savedQueryMatchesSearch)
    }

    @discardableResult
    func activateQueryDocument(
        _ id: UUID
    ) -> WorkspaceDatabaseObjectSelection? {
        guard queryDocuments.contains(where: { $0.id == id }) else { return nil }
        restoredSelectedObject = nil
        guard selectedQueryDocumentID != id || selectedObject != nil else {
            return nil
        }
        let previousObject = selectedObject
        if previousObject != nil {
            selectedObject = nil
        }
        selectedQueryDocumentID = id
        return previousObject
    }

    @discardableResult
    func closeQueryDocument(
        _ id: UUID,
        authorization: WorkspaceQueryDocumentCloseAuthorization = .preservingChanges
    ) async -> WorkspaceQueryDocumentCloseResult {
        guard let index = queryDocuments.firstIndex(where: { $0.id == id })
        else {
            return .closed
        }
        let document = queryDocuments[index]
        if let message = document.preflightCloseFailureMessage {
            return .failed(message: message)
        }
        guard authorization.permitsClosing(document) else {
            return .needsUnsavedChangesDecision
        }

        if document.transactionState == .inTransaction {
            let closeResult = await document.close()
            guard closeResult == .closed else { return closeResult }
            guard authorization.permitsClosing(document) else {
                return .needsUnsavedChangesDecision
            }
            await discardRecoverableDraft(for: document.id)
            detachQueryDocument(id)
            return .closed
        }

        detachQueryDocument(id)
        await discardRecoverableDraft(for: document.id)
        return await document.close()
    }

    @discardableResult
    func detachQueryDocument(
        _ id: UUID
    ) -> WorkspaceQueryDocumentModel? {
        guard let index = queryDocuments.firstIndex(where: { $0.id == id })
        else {
            return nil
        }
        let document = queryDocuments[index]
        let replacementID: UUID? = if selectedQueryDocumentID == id {
            if index + 1 < queryDocuments.count {
                queryDocuments[index + 1].id
            } else if index > 0 {
                queryDocuments[index - 1].id
            } else {
                nil
            }
        } else {
            selectedQueryDocumentID
        }
        queryDocuments.remove(at: index)
        selectedQueryDocumentID = replacementID
        return document
    }

    func discardRecoverableDraft(for documentID: UUID) async {
        recoverableDraftGenerations[documentID, default: 0] += 1
        let cleanupGeneration = recoverableDraftGenerations[
            documentID,
            default: 0
        ]
        let pendingTask = recoverableDraftTasks.removeValue(
            forKey: documentID
        )
        pendingTask?.cancel()
        await pendingTask?.value

        if recoverableDraftGenerations[documentID] != cleanupGeneration,
           queryDocuments.first(where: { $0.id == documentID })?.isDirty == true
        {
            while let newerTask = recoverableDraftTasks[documentID] {
                await newerTask.value
            }
            return
        }

        do {
            try await recoverableDraftRepository.delete(id: documentID)
            recoverableDraftCreatedAt[documentID] = nil
        } catch is CancellationError {
            return
        } catch {
            reportRecoverableDraftError(error)
        }
    }

    func waitForRecoverableDraftPersistence() async {
        while workspaceMoveTask != nil || !recoverableDraftTasks.isEmpty {
            let moveTask = workspaceMoveTask
            let tasks = Array(recoverableDraftTasks.values)
            await moveTask?.value
            for task in tasks {
                await task.value
            }
        }
    }

    private func updateSidebarSelection(
        _ selection: WorkspaceDatabaseObjectSelection?
    ) -> (
        selection: WorkspaceDatabaseObjectSelection,
        reason: WorkspaceDataStopReason
    )? {
        if selection != restoredSelectedObject {
            restoredSelectedObject = nil
        }
        let previousObject = selectedObject

        switch selection {
        case let selection?:
            guard selectedObject != selection
                    || selectedQueryDocumentID != nil
            else {
                return nil
            }
            selectedQueryDocumentID = nil
            selectedObject = selection
            return previousObject.map { ($0, .selectionChanged) }

        case nil:
            guard selectedObject != nil else { return nil }
            selectedObject = nil
            return previousObject.map { ($0, .leftDataTab) }
        }
    }

    func stopDataWork(
        for selection: WorkspaceDatabaseObjectSelection,
        reason: WorkspaceDataStopReason
    ) async {
        let currentState = objectDataStates[selection] ?? .notLoaded
        let hasActiveRowFetch = currentState.isFetching
        let ownsActiveRowFetch = hasActiveRowFetch
            && dataLoadSelection == selection
        let rowSession = ownsActiveRowFetch ? dataSession : nil

        if hasActiveRowFetch {
            if ownsActiveRowFetch {
                dataLoadID = nil
                dataLoadSelection = nil
                clearDataReplacement()
                dataSession = nil
            }
            if reason.preservesPartialPage {
                objectDataStates[selection] = .stopped(currentState.page)
            } else {
                objectDataStates[selection] = .notLoaded
            }
        }

        let hasLoadingCount = objectDataCountStates[selection] == .loading
        let ownsActiveCount = dataCountLoadSelection == selection
        let countSession = ownsActiveCount ? dataCountSession : nil
        if ownsActiveCount {
            dataCountLoadID = nil
            dataCountLoadSelection = nil
            dataCountTask?.cancel()
            dataCountTask = nil
            dataCountSession = nil
        }
        if hasLoadingCount {
            objectDataCountStates[selection] = .notLoaded
        }

        if let rowSession {
            await rowSession.close()
        }
        if let countSession, countSession !== rowSession {
            await countSession.close()
        }
    }

    private func scheduleDataCleanup(
        for selection: WorkspaceDatabaseObjectSelection,
        reason: WorkspaceDataStopReason
    ) {
        let cleanupID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await stopDataWork(for: selection, reason: reason)
            dataCleanupTasks[cleanupID] = nil
        }
        dataCleanupTasks[cleanupID] = task
    }

    func loadDetails(
        for selection: WorkspaceDatabaseObjectSelection,
        force: Bool = false
    ) async {
        guard
            selectedObject == selection,
            let session,
            connectionState == .connected
        else {
            return
        }

        let mutationRevision = elasticsearchMutationRevision
        if !force && (databaseType != .elasticsearch || elasticsearchDetailsRevisions[selection] == mutationRevision) {
            switch objectDetailsStates[selection] ?? .notLoaded {
            case .loading, .loaded:
                return
            case .notLoaded, .failed:
                break
            }
        }

        let retainedState = objectDetailsStates[selection]
        if case .loaded = retainedState {
            // Keep accepted structure content mounted during a forced refresh.
        } else {
            objectDetailsStates[selection] = .loading
        }

        do {
            let details = try await sessionOperationGate.run {
                try await session.fetchDetails(
                    for: selection.object,
                    in: selection.databaseName
                )
            }
            try Task.checkCancellation()
            guard self.session === session, mutationRevision == elasticsearchMutationRevision else { return }
            objectDetailsStates[selection] = .loaded(details)
            elasticsearchDetailsRevisions[selection] = mutationRevision
        } catch is CancellationError {
            if
                self.session === session,
                objectDetailsStates[selection] == .loading
            {
                objectDetailsStates[selection] = .notLoaded
            }
        } catch {
            guard self.session === session else { return }
            objectDetailsStates[selection] = .failed(error.localizedDescription)
        }
    }

    func fetchDocument(
        _ reference: WorkspaceDocumentReference,
        maximumByteCount: Int = 1_048_576
    ) async throws -> WorkspaceDocumentSnapshot {
        guard let session,
              connectionState == .connected,
              let documentSession = session as? any WorkspaceDocumentInspectorSession
        else {
            throw WorkspaceSessionError.queryUnavailable
        }
        return try await sessionOperationGate.run {
            try await documentSession.fetchDocument(
                reference,
                maximumByteCount: maximumByteCount
            )
        }
    }

    func prepareDocumentReplacement(
        _ draft: WorkspaceDocumentReplacementDraft
    ) async throws -> WorkspacePreparedDocumentReplacement {
        guard let session,
              connectionState == .connected,
              let editingSession = session as? any WorkspaceDocumentEditingSession
        else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        return try await sessionOperationGate.run {
            try await editingSession.prepareDocumentReplacement(draft)
        }
    }

    func prepareDocumentCreation(
        _ draft: WorkspaceDocumentCreationDraft
    ) async throws -> WorkspacePreparedDocumentCreation {
        guard let session,
              connectionState == .connected,
              let editingSession = session as? any WorkspaceDocumentEditingSession
        else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        return try await sessionOperationGate.run {
            try await editingSession.prepareDocumentCreation(draft)
        }
    }

    func commitDocumentCreation(
        _ creation: WorkspacePreparedDocumentCreation
    ) async throws -> WorkspaceDocumentCreationResult {
        guard let session,
              connectionState == .connected,
              let editingSession = session as? any WorkspaceDocumentEditingSession
        else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        return try await sessionOperationGate.run {
            try await editingSession.commitDocumentCreation(creation)
        }
    }

    func commitDocumentReplacement(
        _ replacement: WorkspacePreparedDocumentReplacement
    ) async throws -> WorkspaceDocumentReplacementResult {
        guard let session,
              connectionState == .connected,
              let editingSession = session as? any WorkspaceDocumentEditingSession
        else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        return try await sessionOperationGate.run {
            try await editingSession.commitDocumentReplacement(replacement)
        }
    }

    func prepareDocumentPartialUpdate(
        _ draft: WorkspaceDocumentPartialUpdateDraft
    ) async throws -> WorkspacePreparedDocumentPartialUpdate {
        guard let session,
              connectionState == .connected,
              let editingSession = session as? any WorkspaceDocumentEditingSession
        else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        return try await sessionOperationGate.run {
            try await editingSession.prepareDocumentPartialUpdate(draft)
        }
    }

    func commitDocumentPartialUpdate(
        _ update: WorkspacePreparedDocumentPartialUpdate
    ) async throws -> WorkspaceDocumentReplacementResult {
        guard let session,
              connectionState == .connected,
              let editingSession = session as? any WorkspaceDocumentEditingSession
        else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        return try await sessionOperationGate.run {
            try await editingSession.commitDocumentPartialUpdate(update)
        }
    }

    func prepareDocumentDeletion(
        _ draft: WorkspaceDocumentDeletionDraft
    ) async throws -> WorkspacePreparedDocumentDeletion {
        guard let session,
              connectionState == .connected,
              let editingSession = session as? any WorkspaceDocumentEditingSession
        else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        return try await sessionOperationGate.run {
            try await editingSession.prepareDocumentDeletion(draft)
        }
    }

    func commitDocumentDeletion(
        _ deletion: WorkspacePreparedDocumentDeletion
    ) async throws -> WorkspaceDocumentDeletionResult {
        guard let session,
              connectionState == .connected,
              let editingSession = session as? any WorkspaceDocumentEditingSession
        else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        return try await sessionOperationGate.run {
            try await editingSession.commitDocumentDeletion(deletion)
        }
    }

    func loadSchemaChoices() async -> WorkspaceDatabaseSchemaChoices {
        guard
            let session,
            connectionState == .connected
        else {
            return .empty
        }
        return (try? await sessionOperationGate.run {
            await session.fetchSchemaChoices()
        }) ?? .empty
    }

    func loadIndexes(
        for selection: WorkspaceDatabaseObjectSelection,
        force: Bool = false
    ) async {
        guard
            selection.kind == .table,
            selectedObject == selection,
            let session,
            connectionState == .connected
        else {
            return
        }

        if !force {
            switch objectIndexesStates[selection] ?? .notLoaded {
            case .loading, .loaded:
                return
            case .notLoaded, .failed:
                break
            }
        }

        let retainedState = objectIndexesStates[selection]
        if case .loaded = retainedState {
            // Keep accepted index content mounted during a forced refresh.
        } else {
            objectIndexesStates[selection] = .loading
        }

        do {
            let indexes = try await sessionOperationGate.run {
                try await session.fetchIndexes(
                    for: selection.object,
                    in: selection.databaseName
                )
            }
            try Task.checkCancellation()
            guard self.session === session else { return }
            objectIndexesStates[selection] = .loaded(indexes)
        } catch is CancellationError {
            if
                self.session === session,
                objectIndexesStates[selection] == .loading
            {
                objectIndexesStates[selection] = .notLoaded
            }
        } catch {
            guard self.session === session else { return }
            objectIndexesStates[selection] = .failed(error.localizedDescription)
        }
    }

    func loadData(
        for selection: WorkspaceDatabaseObjectSelection,
        offset requestedOffset: Int,
        limit: Int = WorkspaceDatabaseDataPage.defaultLimit,
        sort: WorkspaceDatabaseDataSort = .none,
        filter: WorkspaceDatabaseDataFilter = .empty,
        force: Bool = false
    ) async {
        guard
            selectedObject == selection,
            let session,
            connectionState == .connected,
            !Task.isCancelled,
            requestedOffset >= 0,
            limit > 0
        else {
            return
        }

        let mutationRevision = elasticsearchMutationRevision
        let force = force || (databaseType == .elasticsearch && mutationRevision > 0
            && elasticsearchDataRevisions[selection] != mutationRevision)
        if !force {
            switch objectDataStates[selection] ?? .notLoaded {
            case .loading
                where objectDataOffsets[selection] == requestedOffset
                    && objectDataLimits[selection] == limit
                    && objectDataSorts[selection] == sort
                    && objectDataFilters[selection] == filter:
                return
            case let .fetching(page)
                where page.offset == requestedOffset
                    && page.limit == limit
                    && page.sort == sort
                    && objectDataFilters[selection] == filter:
                return
            case let .loaded(page)
                where page.offset == requestedOffset
                    && page.limit == limit
                    && page.sort == sort
                    && objectDataFilters[selection] == filter:
                return
            case .stopped
                where objectDataOffsets[selection] == requestedOffset
                    && objectDataLimits[selection] == limit
                    && objectDataSorts[selection] == sort
                    && objectDataFilters[selection] == filter:
                return
            case .notLoaded, .loading, .fetching, .stopped, .loaded, .failed:
                break
            }
        }

        let currentPage = objectDataStates[selection]?.page
        let refreshesDocuments = force && databaseType == .elasticsearch
        let replacesCurrentPage = force
            && (currentPage?.offset == requestedOffset || refreshesDocuments)
            && currentPage?.limit == limit
            && currentPage?.sort == sort
            && currentPage?.filter == filter
        let previousPage: WorkspaceDatabaseDataPage?
        if replacesCurrentPage {
            previousPage = currentPage
        } else if
            let currentPage,
            currentPage.offset != requestedOffset
                || currentPage.limit != limit
                || currentPage.sort != sort
                || currentPage.filter != filter
        {
            previousPage = currentPage
        } else {
            previousPage = nil
        }

        if dataLoadID != nil || refreshesDocuments, let dataSession {
            let supersededSelection = dataLoadSelection
            dataLoadID = nil
            dataLoadSelection = nil
            clearDataReplacement()
            self.dataSession = nil
            if let supersededSelection {
                let supersededPage = objectDataStates[supersededSelection]?.page
                objectDataStates[supersededSelection] = supersededPage.map {
                    .stopped($0)
                } ?? .notLoaded
            }
            await dataSession.close()
            guard !Task.isCancelled, self.dataSession == nil, dataLoadID == nil else { return }
        }
        guard
            self.session === session,
            selectedObject == selection
        else {
            return
        }

        let loadID = UUID()
        dataLoadID = loadID
        dataLoadSelection = selection
        if replacesCurrentPage {
            dataReplacementLoadID = loadID
            dataReplacementRowStore = WorkspaceDatabaseDataRowStore()
        } else {
            clearDataReplacement()
        }
        objectDataOffsets[selection] = requestedOffset
        objectDataLimits[selection] = limit
        objectDataSorts[selection] = sort
        objectDataFilters[selection] = filter
        objectDataStates[selection] = previousPage.map {
            .fetching($0)
        } ?? .loading

        var fetchSession: any WorkspaceSession
        do {
            fetchSession = try await connectedDataSession()
        } catch is CancellationError {
            if dataLoadID == loadID, dataLoadSelection == selection {
                dataLoadID = nil
                dataLoadSelection = nil
                clearDataReplacement(for: loadID)
                objectDataStates[selection] = .stopped(
                    objectDataStates[selection]?.page
                )
            }
            return
        } catch {
            guard
                selectedObject == selection,
                dataLoadID == loadID,
                dataLoadSelection == selection
            else {
                return
            }
            dataLoadID = nil
            dataLoadSelection = nil
            clearDataReplacement(for: loadID)
            objectDataStates[selection] = .failed(error.localizedDescription)
            return
        }
        guard
            self.session === session,
            selectedObject == selection,
            dataLoadID == loadID,
            dataLoadSelection == selection
        else {
            if dataSession === fetchSession {
                dataSession = nil
                await fetchSession.close()
            }
            return
        }

        await startDataCountIfNeeded(
            for: selection,
            filter: filter,
            force: force
        )
        if refreshesDocuments, let countTask = dataCountTask {
            await withTaskCancellationHandler {
                await countTask.value
            } onCancel: {
                countTask.cancel()
            }
        }
        guard
            self.session === session,
            selectedObject == selection,
            dataLoadID == loadID,
            dataLoadSelection == selection
        else {
            if dataSession === fetchSession {
                dataSession = nil
                await fetchSession.close()
            }
            return
        }

        let offset: Int
        if refreshesDocuments {
            let count: Int?
            if case .loaded(let value) = objectDataCountStates[selection] {
                count = value
            } else {
                count = nil
            }
            offset = WorkspaceElasticsearchPageRefresh.offset(
                requested: requestedOffset, limit: limit, totalCount: count
            )
            objectDataOffsets[selection] = offset
        } else {
            offset = requestedOffset
        }

        do {
            try Task.checkCancellation()
            let result: WorkspaceDatabaseDataFetchResult
            do {
                result = try await fetchSession.fetchDataPage(
                    for: selection.object,
                    in: selection.databaseName,
                    offset: offset,
                    limit: limit,
                    sort: sort,
                    filter: filter
                ) { [weak self] batch in
                    await self?.appendDataBatch(
                        batch,
                        for: selection,
                        offset: offset,
                        limit: limit,
                        sort: sort,
                        filter: filter,
                        loadID: loadID,
                        session: session
                    )
                }
            } catch {
                if error is CancellationError { throw error }
                guard !(await fetchSession.isConnected()) else { throw error }
                if dataSession === fetchSession {
                    dataSession = nil
                }
                await fetchSession.close()
                try Task.checkCancellation()
                guard
                    self.session === session,
                    selectedObject == selection,
                    dataLoadID == loadID,
                    dataLoadSelection == selection,
                    objectDataOffsets[selection] == offset,
                    objectDataLimits[selection] == limit,
                    objectDataSorts[selection] == sort,
                    objectDataFilters[selection] == filter
                else {
                    throw CancellationError()
                }

                if replacesCurrentPage {
                    dataReplacementLoadID = loadID
                    dataReplacementRowStore = WorkspaceDatabaseDataRowStore()
                } else {
                    clearDataReplacement(for: loadID)
                }
                objectDataStates[selection] = previousPage.map {
                    .fetching($0)
                } ?? .loading
                fetchSession = try await connectedDataSession()
                result = try await fetchSession.fetchDataPage(
                    for: selection.object,
                    in: selection.databaseName,
                    offset: offset,
                    limit: limit,
                    sort: sort,
                    filter: filter
                ) { [weak self] batch in
                    await self?.appendDataBatch(
                        batch,
                        for: selection,
                        offset: offset,
                        limit: limit,
                        sort: sort,
                        filter: filter,
                        loadID: loadID,
                        session: session
                    )
                }
            }
            try Task.checkCancellation()
            guard
                self.session === session,
                selectedObject == selection,
                dataLoadID == loadID,
                dataLoadSelection == selection,
                objectDataOffsets[selection] == offset,
                objectDataLimits[selection] == limit,
                objectDataSorts[selection] == sort,
                objectDataFilters[selection] == filter
            else {
                if dataLoadID == loadID, dataLoadSelection == selection {
                    dataLoadID = nil
                    dataLoadSelection = nil
                    clearDataReplacement(for: loadID)
                    objectDataStates[selection] = .notLoaded
                }
                return
            }

            let rowStore: WorkspaceDatabaseDataRowStore
            if dataReplacementLoadID == loadID,
               let dataReplacementRowStore
            {
                rowStore = dataReplacementRowStore
            } else if
                case let .fetching(page) = objectDataStates[selection],
                page.offset == offset,
                page.limit == limit,
                page.sort == sort,
                page.filter == filter
            {
                rowStore = page.rowStore
            } else {
                rowStore = WorkspaceDatabaseDataRowStore()
            }
            let page = WorkspaceDatabaseDataPage(
                columns: result.columns,
                rowStore: rowStore,
                offset: offset,
                limit: limit,
                hasNextPage: result.hasNextPage,
                sort: sort,
                filter: filter
            )
            dataLoadID = nil
            dataLoadSelection = nil
            clearDataReplacement(for: loadID)
            objectDataStates[selection] = .loaded(page)
            if databaseType == .elasticsearch { elasticsearchDataRevisions[selection] = mutationRevision }
            await updateDataCount(
                for: selection,
                page: page,
                filter: filter,
                force: force && !refreshesDocuments
            )
        } catch is CancellationError {
            guard
                dataLoadID == loadID,
                dataLoadSelection == selection
            else {
                return
            }
            dataLoadID = nil
            dataLoadSelection = nil
            clearDataReplacement(for: loadID)
            if
                self.session === session,
                objectDataOffsets[selection] == offset,
                objectDataLimits[selection] == limit,
                objectDataSorts[selection] == sort,
                objectDataFilters[selection] == filter
            {
                objectDataStates[selection] = .stopped(
                    objectDataStates[selection]?.page
                )
            }
            if let dataSession, dataSession === fetchSession {
                self.dataSession = nil
                await fetchSession.close()
            }
        } catch {
            guard
                dataLoadID == loadID,
                dataLoadSelection == selection
            else {
                return
            }
            dataLoadID = nil
            dataLoadSelection = nil
            clearDataReplacement(for: loadID)
            if
                self.session === session,
                objectDataOffsets[selection] == offset,
                objectDataLimits[selection] == limit,
                objectDataSorts[selection] == sort,
                objectDataFilters[selection] == filter
            {
                objectDataStates[selection] = selectedObject == selection
                    ? .failed(error.localizedDescription)
                    : .notLoaded
            }
            if let dataSession, dataSession === fetchSession {
                self.dataSession = nil
                await fetchSession.close()
            }
        }
    }

    @discardableResult
    func refreshDatabases() async -> DatabaseRefreshResult {
        guard let session, connectionState == .connected else {
            return .reconnectRequired
        }
        await reloadSavedQueries()

        do {
            guard await session.isConnected() else {
                return .reconnectRequired
            }
            let logicalDatabases: [RedisLogicalDatabase]
            let names: [String]
            if let redisSession = session as? any RedisWorkspaceSession {
                logicalDatabases = try await sessionOperationGate.run {
                    try await redisSession.fetchRedisLogicalDatabases()
                }
                names = logicalDatabases.map(\.name)
            } else {
                logicalDatabases = []
                names = try await sessionOperationGate.run {
                    try await session.fetchDatabases()
                }
            }
            try Task.checkCancellation()
            guard self.session === session else { return .cancelled }
            adoptImplicitDatabaseContextIfNeeded(from: names)
            databases = makeDatabases(from: names, preserving: databases)
            redisLogicalDatabases = logicalDatabases
            if databaseType == .postgresql,
               let databaseContextName
            {
                let schemaNames = (try? await sessionOperationGate.run {
                    try await session.fetchSchemas(in: databaseContextName)
                }) ?? []
                guard self.session === session else { return .cancelled }
                replaceAvailableSchemas(schemaNames)
            }
            if databaseType == .redis {
                await loadRedisKeys(reset: true)
            } else if let databaseContextName,
               names.contains(databaseContextName)
            {
                _ = await refreshObjects(in: databaseContextName)
            }
            if databaseType != .redis {
                guard let sessionConfiguration else { return .reconnectRequired }
                _ = await schemaCatalogCoordinator.startRefresh(
                    configuration: sessionConfiguration
                )
            }
            return .refreshed
        } catch is CancellationError {
            return .cancelled
        } catch {
            connectionState = .failed(error.localizedDescription)
            return .reconnectRequired
        }
    }

    var currentRedisDatabaseIndex: Int {
        guard databaseType == .redis,
              let name = databaseContextName
        else { return 0 }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("db ") {
            return Int(trimmed.dropFirst(3)) ?? 0
        }
        return Int(trimmed) ?? 0
    }

    private func adoptImplicitDatabaseContextIfNeeded(from names: [String]) {
        guard databaseType == .elasticsearch,
              databaseContextName == nil
        else { return }
        databaseContextName = names.first
    }

    var redisKeySearchRequest: RedisKeySearchRequest {
        RedisKeySearchRequest(
            text: searchText,
            mode: searchText.isEmpty || !isRedisKeyExactSearch
                ? .contains
                : .exact
        )
    }

    var activeRedisKeySearchText: String {
        activeRedisKeySearch.text
    }

    var currentRedisDatabaseReportedKeyCount: Int? {
        redisLogicalDatabases.first {
            $0.index == currentRedisDatabaseIndex
        }?.keyCount
    }

    func loadRedisKeys(reset: Bool) async {
        redisKeyLoadTask?.cancel()
        redisKeyLoadGeneration &+= 1
        let generation = redisKeyLoadGeneration
        await performRedisKeyLoad(
            reset: reset,
            scope: redisKeyPageLoadScope(for: activeRedisKeySearch),
            generation: generation,
            search: activeRedisKeySearch
        )
    }

    func startRedisKeyLoad(reset: Bool, scope: RedisKeyLoadScope) {
        let search = activeRedisKeySearch
        startRedisKeyLoad(
            reset: reset,
            scope: scope,
            search: search
        )
    }

    private func startRedisKeyLoad(
        reset: Bool,
        scope: RedisKeyLoadScope,
        search: RedisKeySearchRequest
    ) {
        redisKeyLoadTask?.cancel()
        redisKeyLoadGeneration &+= 1
        let generation = redisKeyLoadGeneration
        if reset, search != activeRedisKeySearch {
            // Keep the sidebar geometry stable without showing the unrelated
            // pre-search tree while cached matches are prepared off MainActor.
            isLoadingRedisKeys = true
            isLoadingAllRedisKeys = scope == .allRemaining
            redisKeyTree = []
        }
        redisKeyLoadTask = Task { [weak self] in
            await self?.performRedisKeyLoad(
                reset: reset,
                scope: scope,
                generation: generation,
                search: search
            )
        }
    }

    func submitRedisKeySearch() {
        let search = redisKeySearchRequest
        startRedisKeyLoad(
            reset: true,
            scope: redisKeyPageLoadScope(for: search),
            search: search
        )
    }

    func startRedisKeyPageLoad(reset: Bool) {
        startRedisKeyLoad(
            reset: reset,
            scope: redisKeyPageLoadScope(for: activeRedisKeySearch)
        )
    }

    func stopRedisKeyLoading() {
        redisKeyLoadTask?.cancel()
    }

    private func redisKeyPageLoadScope(
        for search: RedisKeySearchRequest
    ) -> RedisKeyLoadScope {
        search.text.isEmpty ? .nextPage : .matchingPage
    }

    private func performRedisKeyLoad(
        reset: Bool,
        scope: RedisKeyLoadScope,
        generation: Int,
        search: RedisKeySearchRequest
    ) async {
        guard databaseType == .redis,
              connectionState == .connected,
              let activeSession = session,
              let redisSession = activeSession as? any RedisWorkspaceSession
        else { return }

        isLoadingRedisKeys = true
        isLoadingAllRedisKeys = scope == .allRemaining
        defer {
            if redisKeyLoadGeneration == generation {
                isLoadingRedisKeys = false
                isLoadingAllRedisKeys = false
                redisKeyLoadTask = nil
            }
        }
        redisKeyLoadErrorMessage = nil
        let databaseIndex = currentRedisDatabaseIndex
        let previouslyLoadedKeys = redisKeys
        let effectiveReset = reset || search != activeRedisKeySearch
        if effectiveReset {
            redisKeyScanCursor = 0
            isRedisKeyScanComplete = false
            redisKeyLoadDiscoveredCount = 0
            activeRedisKeySearch = search

            redisTreeBuildGeneration &+= 1
            let interimTreeGeneration = redisTreeBuildGeneration
            let interimTree: [RedisKeyTreeNode]
            if search.text.isEmpty {
                interimTree = []
            } else {
                interimTree = await redisKeyTreeBuilder.build(
                    keys: previouslyLoadedKeys,
                    matching: search
                )
            }
            guard !Task.isCancelled else { return }
            guard redisKeyLoadGeneration == generation,
                  session === activeSession,
                  currentRedisDatabaseIndex == databaseIndex,
                  activeRedisKeySearch == search,
                  redisTreeBuildGeneration == interimTreeGeneration
            else { return }

            redisKeyTree = interimTree
            if let selection = redisSidebarSelection,
               !interimTree.contains(reference: selection)
            {
                redisSidebarSelection = nil
            }
        }
        let existingKeys = effectiveReset ? [] : redisKeys
        let cursor = effectiveReset ? 0 : redisKeyScanCursor
        let operationGate = sessionOperationGate

        do {
            let result = try await redisKeyScanLoader.load(
                existingKeys: existingKeys,
                cursor: cursor,
                search: search,
                databaseIndex: databaseIndex,
                scope: scope,
                fetchPage: { cursor, pattern, count in
                    try await operationGate.run {
                        try await redisSession.scanRedisKeys(
                            databaseIndex: databaseIndex,
                            cursor: cursor,
                            pattern: pattern,
                            count: count
                        )
                    }
                },
                exactLookup: { key in
                    let invocation = RedisCommandInvocation(
                        source: "EXISTS",
                        arguments: ["EXISTS", key]
                    )
                    let result = try await operationGate.run {
                        try await redisSession.executeRedisCommand(
                            invocation,
                            databaseIndex: databaseIndex
                        )
                    }
                    guard case let .integer(count) = result.reply else {
                        throw RedisWorkspaceError.invalidReply("EXISTS")
                    }
                    return count > 0
                },
                progress: { [weak self] progress in
                    await self?.applyRedisKeyScanProgress(
                        progress,
                        generation: generation
                    )
                }
            )
            try Task.checkCancellation()
            guard redisKeyLoadGeneration == generation,
                  session === activeSession,
                  currentRedisDatabaseIndex == databaseIndex,
                  activeRedisKeySearch == search
            else { return }

            redisTreeBuildGeneration &+= 1
            let treeGeneration = redisTreeBuildGeneration
            let tree = await redisKeyTreeBuilder.build(
                keys: result.keys,
                matching: ""
            )
            try Task.checkCancellation()
            guard redisKeyLoadGeneration == generation,
                  session === activeSession,
                  currentRedisDatabaseIndex == databaseIndex,
                  activeRedisKeySearch == search,
                  redisTreeBuildGeneration == treeGeneration
            else { return }

            redisKeys = result.keys
            redisKeyTree = tree
            redisKeyLoadDiscoveredCount = result.keys.count
            redisKeyScanCursor = result.nextCursor
            isRedisKeyScanComplete = result.nextCursor == 0
            if let selection = redisSidebarSelection,
               !result.keys.contains(selection)
            {
                redisSidebarSelection = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard redisKeyLoadGeneration == generation,
                  session === activeSession
            else { return }
            redisKeyLoadErrorMessage = error.localizedDescription
        }
    }

    private func applyRedisKeyScanProgress(
        _ progress: RedisKeyScanProgress,
        generation: Int
    ) {
        guard redisKeyLoadGeneration == generation else { return }
        redisKeyLoadDiscoveredCount = progress.discoveredKeyCount
    }

    func rebuildRedisKeyTree() async {
        redisTreeBuildGeneration &+= 1
        let generation = redisTreeBuildGeneration
        let keys = redisKeys
        let tree = await redisKeyTreeBuilder.build(
            keys: keys,
            matching: ""
        )
        guard generation == redisTreeBuildGeneration else { return }
        redisKeyTree = tree
    }

    func fetchRedisKeyDetails(
        _ reference: RedisKeyReference
    ) async throws -> RedisKeyDetails {
        guard connectionState == .connected,
              let activeSession = session,
              let redisSession = activeSession as? any RedisWorkspaceSession
        else { throw RedisWorkspaceError.unavailable }
        let usesCapabilityValueLoading = switch reference.type {
        case .string:
            activeSession is any RedisBinaryStringSession
        case .list, .hash, .set, .sortedSet:
            activeSession is any RedisCollectionPagingSession
        case .stream, .module, .unknown, .none:
            false
        }
        let details = try await sessionOperationGate.run {
            try await redisSession.fetchRedisKey(
                reference,
                maximumElements: usesCapabilityValueLoading ? 0 : 500
            )
        }
        guard session === activeSession else {
            throw RedisWorkspaceError.unavailable
        }
        if details.reference.type == .hash {
            var seen = Set<String>()
            redisHashFieldsByKey[details.reference] = details.value.rows
                .compactMap(\.first)
                .filter { seen.insert($0).inserted }
        } else {
            redisHashFieldsByKey.removeValue(forKey: details.reference)
        }
        return details
    }

    func fetchRedisCollectionPage(
        _ query: RedisCollectionQuery
    ) async throws -> RedisCollectionPage? {
        guard connectionState == .connected,
              let activeSession = session,
              let pagingSession = activeSession
                as? any RedisCollectionPagingSession
        else { return nil }
        let page = try await sessionOperationGate.run {
            try await pagingSession.fetchRedisCollectionPage(query)
        }
        guard session === activeSession else {
            throw RedisWorkspaceError.unavailable
        }
        if query.reference.type == .hash {
            var fields = redisHashFieldsByKey[query.reference] ?? []
            var seen = Set(fields)
            for entry in page.entries {
                guard case let .hash(field, _, _) = entry,
                      let text = field.losslessUTF8String,
                      seen.insert(text).inserted
                else { continue }
                fields.append(text)
            }
            redisHashFieldsByKey[query.reference] = fields
        }
        return page
    }

    func fetchRedisStringChunk(
        _ reference: RedisKeyReference,
        offset: Int,
        maximumBytes: Int
    ) async throws -> RedisStringChunk? {
        guard connectionState == .connected,
              let activeSession = session,
              let binarySession = activeSession
                as? any RedisBinaryStringSession
        else { return nil }
        let chunk = try await sessionOperationGate.run {
            try await binarySession.fetchRedisStringChunk(
                reference,
                offset: offset,
                maximumBytes: maximumBytes
            )
        }
        guard session === activeSession else {
            throw RedisWorkspaceError.unavailable
        }
        return chunk
    }

    func resolveRedisKeyTypes(
        _ references: [RedisKeyReference]
    ) async throws -> [RedisKeyReference] {
        guard !references.isEmpty,
              connectionState == .connected,
              let activeSession = session,
              let resolvingSession = activeSession
                as? any RedisKeyTypeResolvingSession
        else { return references }
        let resolved = try await sessionOperationGate.run {
            try await resolvingSession.resolveRedisKeyTypes(references)
        }
        guard session === activeSession else {
            throw RedisWorkspaceError.unavailable
        }
        var didChange = false
        for reference in resolved where reference.type != .unknown {
            guard let index = redisKeys.firstIndex(of: reference),
                  redisKeys[index].type != reference.type
            else { continue }
            redisKeys[index] = reference
            didChange = true
        }
        if didChange {
            await rebuildRedisKeyTree()
        }
        return resolved
    }

    func resolveRedisKeyReference(_ reference: RedisKeyReference) async {
        guard reference.type != .unknown,
              let index = redisKeys.firstIndex(of: reference),
              redisKeys[index].type != reference.type
        else { return }
        redisKeys[index] = reference
        await rebuildRedisKeyTree()
    }

    func executeRedisCommand(
        _ invocation: RedisCommandInvocation,
        databaseIndex: Int
    ) async throws -> RedisCommandResult {
        guard connectionState == .connected,
              let activeSession = session,
              let redisSession = activeSession as? any RedisWorkspaceSession
        else { throw RedisWorkspaceError.unavailable }
        let result = try await sessionOperationGate.run {
            try await redisSession.executeRedisCommand(
                invocation,
                databaseIndex: databaseIndex
            )
        }
        guard session === activeSession else {
            throw RedisWorkspaceError.unavailable
        }
        return result
    }

    @ObservationIgnored var elasticsearchHasPendingChanges: @MainActor () -> Bool = { false }
    @ObservationIgnored var openElasticsearchRequestSource: @MainActor (String) -> Void = { _ in }
    private(set) var elasticsearchMutationRevision = 0
    private var elasticsearchDetailsRevisions: [WorkspaceDatabaseObjectSelection: Int] = [:]
    private var elasticsearchDataRevisions: [WorkspaceDatabaseObjectSelection: Int] = [:]

    func authorizeElasticsearchRequests(_ requests: [WorkspaceRequest]) throws {
        guard connectionState == .connected else { throw WorkspaceSessionError.notConnected }
        if safetyLock.isEnabled, requests.contains(where: WorkspaceRequestClassifier.requiresWriteAccess) {
            throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled
        }
        for request in requests {
            try WorkspaceRequestClassifier.validate(request, policy: safetyLock.isEnabled ? .readOnly : .writesAllowed)
        }
        // Console execution is independent of staged table/Mapping changes.
        // Those drafts retain their own baseline and validate conflicts when committed.
    }

    func executeElasticsearchRequest(
        _ request: WorkspaceRequest
    ) async throws -> WorkspaceRequestExecutionResult {
        try authorizeElasticsearchRequests([request])
        guard connectionState == .connected,
              let activeSession = session,
              let requestSession = activeSession
                as? any WorkspaceRequestExecutingSession
        else { throw WorkspaceSessionError.queryUnavailable }
        let policy: WorkspaceRequestExecutionPolicy = safetyLock.isEnabled ? .readOnly : .writesAllowed
        let result = try await sessionOperationGate.run {
            do {
                try await self.validateElasticsearchRequestSession(activeSession, request: request)
                try Task.checkCancellation()
            } catch {
                throw WorkspaceElasticsearchRequestNotSentError(message: error.localizedDescription)
            }
            return try await requestSession.executeRequest(request, policy: policy)
        }
        // The completed response belongs to the original connection even if it closed afterward.
        return result
    }

    private func validateElasticsearchRequestSession(_ activeSession: any WorkspaceSession, request: WorkspaceRequest) throws {
        guard session === activeSession else { throw WorkspaceSessionError.notConnected }
        try authorizeElasticsearchRequests([request])
    }

    func deleteElasticsearchIndex(_ prepared: WorkspacePreparedIndexDeletion) async throws -> WorkspaceRequestExecutionResult {
        let worker = WorkspaceIndexDeletionWorker()
        let activeSession: any WorkspaceSession
        let requestSession: any WorkspaceRequestExecutingSession
        do {
            let expected = try await worker.prepare(prepared.selection)
            guard expected == prepared else { throw WorkspaceIndexDeletionError.ordinaryIndexRequired }
            guard let connected = session, let executor = connected as? any WorkspaceRequestExecutingSession else {
                throw WorkspaceSessionError.notConnected
            }
            activeSession = connected
            requestSession = executor
            try validateElasticsearchIndexDeletionSession(activeSession, request: prepared.request)
        } catch {
            throw WorkspaceIndexDeletionNotSentError(message: error.localizedDescription)
        }
        return try await sessionOperationGate.run {
            do {
                try await self.validateElasticsearchIndexDeletionSession(activeSession, request: prepared.request)
                try Task.checkCancellation()
                let resolution = try await requestSession.executeRequest(prepared.resolutionRequest, policy: .readOnly)
                let exists = try await worker.validateResolution(resolution, for: prepared)
                if !exists { return resolution }
                // Drafts, lock and connection can change during the metadata read.
                try await self.validateElasticsearchIndexDeletionSession(activeSession, request: prepared.request)
                try Task.checkCancellation()
            } catch let error as WorkspaceIndexDeletionNotSentError {
                throw error
            } catch {
                throw WorkspaceIndexDeletionNotSentError(message: error.localizedDescription)
            }
            return try await requestSession.executeRequest(prepared.request, policy: .writesAllowed)
        }
    }

    private func validateElasticsearchIndexDeletionSession(_ activeSession: any WorkspaceSession, request: WorkspaceRequest) throws {
        try validateElasticsearchRequestSession(activeSession, request: request)
        guard !elasticsearchHasPendingChanges() else { throw WorkspaceIndexDeletionError.pendingChanges }
    }

    func fetchElasticsearchMapping(_ target: WorkspaceMappingTarget) async throws -> WorkspaceMappingSnapshot {
        guard let activeSession = session, let mapping = activeSession as? any WorkspaceMappingEditingSession else { throw WorkspaceSessionError.notConnected }
        let result = try await sessionOperationGate.run { try await mapping.fetchMappingSnapshot(target) }
        guard session === activeSession else { throw WorkspaceSessionError.notConnected }
        return result
    }

    func commitElasticsearchIndexSettings(_ prepared: WorkspacePreparedIndexSettings) async throws -> WorkspaceRequestExecutionResult {
        let worker = WorkspaceIndexSettingsWorker()
        let activeSession: any WorkspaceSession
        let executor: any WorkspaceRequestExecutingSession
        do {
            try await worker.validatePrepared(prepared)
            guard let connected = session, let requestSession = connected as? any WorkspaceRequestExecutingSession else {
                throw WorkspaceSessionError.notConnected
            }
            activeSession = connected; executor = requestSession
            try validateElasticsearchRequestSession(activeSession, request: prepared.request)
        } catch { throw WorkspaceIndexSettingsNotSentError(message: error.localizedDescription) }
        return try await sessionOperationGate.run {
            do {
                try await self.validateElasticsearchRequestSession(activeSession, request: prepared.request)
                try Task.checkCancellation()
                let request = try await worker.settingsRequest(prepared.baseline.selection)
                let current = try await executor.executeRequest(request, policy: .readOnly)
                try await worker.validateBaseline(prepared, response: current)
                try await self.validateElasticsearchRequestSession(activeSession, request: prepared.request)
                try Task.checkCancellation()
            } catch { throw WorkspaceIndexSettingsNotSentError(message: error.localizedDescription) }
            return try await executor.executeRequest(prepared.request, policy: .writesAllowed)
        }
    }

    func commitElasticsearchAliases(
        _ prepared: WorkspacePreparedElasticsearchAliasUpdate
    ) async throws -> WorkspaceRequestExecutionResult {
        let worker = WorkspaceElasticsearchAliasWorker()
        let activeSession: any WorkspaceSession
        let executor: any WorkspaceRequestExecutingSession
        do {
            try await worker.validatePrepared(prepared)
            guard let connected = session,
                  let requestSession = connected as? any WorkspaceRequestExecutingSession else {
                throw WorkspaceSessionError.notConnected
            }
            activeSession = connected
            executor = requestSession
            try validateElasticsearchRequestSession(activeSession, request: prepared.request)
        } catch {
            throw WorkspaceElasticsearchAliasNotSentError(message: error.localizedDescription)
        }
        return try await sessionOperationGate.run {
            do {
                try await self.validateElasticsearchRequestSession(activeSession, request: prepared.request)
                try Task.checkCancellation()
                let request = try await worker.readRequest(prepared.baseline.selection)
                let current = try await executor.executeRequest(request, policy: .readOnly)
                try await worker.validateBaseline(prepared, response: current)
                try await self.validateElasticsearchRequestSession(activeSession, request: prepared.request)
                try Task.checkCancellation()
            } catch {
                throw WorkspaceElasticsearchAliasNotSentError(message: error.localizedDescription)
            }
            return try await executor.executeRequest(prepared.request, policy: .writesAllowed)
        }
    }

    func commitElasticsearchIndexTemplate(
        _ prepared: WorkspacePreparedElasticsearchIndexTemplateMutation
    ) async throws -> WorkspaceRequestExecutionResult {
        let worker = WorkspaceElasticsearchIndexTemplateWorker()
        let activeSession: any WorkspaceSession
        let executor: any WorkspaceRequestExecutingSession
        do {
            try await worker.validatePrepared(prepared)
            guard let connected = session,
                  let requestSession = connected as? any WorkspaceRequestExecutingSession else {
                throw WorkspaceSessionError.notConnected
            }
            activeSession = connected
            executor = requestSession
            try validateElasticsearchIndexTemplateSession(activeSession, request: prepared.request)
        } catch {
            throw WorkspaceElasticsearchIndexTemplateNotSentError(message: error.localizedDescription)
        }
        return try await sessionOperationGate.run {
            do {
                try await self.validateElasticsearchIndexTemplateSession(activeSession, request: prepared.request)
                try Task.checkCancellation()
                let current = try await executor.executeRequest(prepared.verificationRequest, policy: .readOnly)
                try await worker.validateBaseline(prepared, response: current)
                try await self.validateElasticsearchIndexTemplateSession(activeSession, request: prepared.request)
                try Task.checkCancellation()
            } catch {
                throw WorkspaceElasticsearchIndexTemplateNotSentError(message: error.localizedDescription)
            }
            return try await executor.executeRequest(prepared.request, policy: .writesAllowed)
        }
    }

    private func validateElasticsearchIndexTemplateSession(
        _ activeSession: any WorkspaceSession,
        request: WorkspaceRequest
    ) throws {
        try validateElasticsearchRequestSession(activeSession, request: request)
        guard !elasticsearchHasPendingChanges() else {
            throw WorkspaceElasticsearchIndexTemplateError.pendingChanges
        }
    }

    func prepareElasticsearchMapping(_ draft: WorkspaceMappingDraft) async throws -> WorkspacePreparedMappingUpdate {
        guard let mapping = session as? any WorkspaceMappingEditingSession else { throw WorkspaceSessionError.notConnected }
        return try await mapping.prepareMappingUpdate(draft)
    }

    func commitElasticsearchMapping(_ prepared: WorkspacePreparedMappingUpdate) async throws -> WorkspaceRequestExecutionResult {
        guard !safetyLock.isEnabled else { throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled }
        guard let activeSession = session, let mapping = activeSession as? any WorkspaceMappingEditingSession else { throw WorkspaceSessionError.notConnected }
        let result = try await sessionOperationGate.run {
            try await self.validateElasticsearchRequestSession(activeSession, request: prepared.request)
            return try await mapping.commitMappingUpdate(prepared)
        }
        guard session === activeSession else { throw WorkspaceSessionError.notConnected }
        return result
    }

    func didMutateElasticsearchMapping() async {
        for load in elasticsearchCompletionFieldLoads.values { load.task.cancel() }
        elasticsearchCompletionFieldLoads.removeAll()
        elasticsearchMutationRevision += 1
        if let name = databaseContextName { _ = await refreshObjects(in: name) }
    }

    func commitRedisKeyChanges(
        _ commands: [RedisCommandInvocation],
        for reference: RedisKeyReference
    ) async throws {
        guard !commands.isEmpty else { return }
        guard !safetyLock.isEnabled else {
            throw RedisKeyEditError.safetyLockEnabled
        }
        guard connectionState == .connected,
              let activeSession = session,
              let mutationSession = activeSession
                as? any RedisTransactionalMutationSession
        else {
            throw RedisKeyEditError.transactionUnavailable
        }
        do {
            try await sessionOperationGate.run {
                try await mutationSession.executeRedisTransaction(
                    commands,
                    databaseIndex: reference.databaseIndex
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RedisKeyEditError {
            throw error
        } catch {
            throw RedisKeyEditError.transactionFailed(error.localizedDescription)
        }
        guard session === activeSession,
              connectionState == .connected
        else {
            throw RedisKeyEditError.unavailable
        }
    }

    func commitRedisOptimisticMutation(
        _ request: RedisOptimisticMutationRequest,
        previewCommands: [RedisCommandInvocation]
    ) async throws {
        guard !previewCommands.isEmpty else { return }
        guard !safetyLock.isEnabled else {
            throw RedisKeyEditError.safetyLockEnabled
        }
        guard connectionState == .connected,
              let activeSession = session,
              let mutationSession = activeSession
                as? any RedisOptimisticMutationSession
        else {
            throw RedisKeyEditError.transactionUnavailable
        }
        do {
            try await sessionOperationGate.run {
                try await mutationSession.executeRedisOptimisticMutation(
                    request
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RedisKeyEditError {
            throw error
        } catch {
            throw RedisKeyEditError.transactionFailed(
                error.localizedDescription
            )
        }
        guard session === activeSession,
              connectionState == .connected
        else {
            throw RedisKeyEditError.unavailable
        }
    }

    func deleteRedisKey(_ reference: RedisKeyReference) async throws {
        let invocation = RedisCommandInvocation(
            source: "DEL \(reference.name)",
            arguments: ["DEL", reference.name]
        )
        try await commitRedisKeyChanges([invocation], for: reference)
        redisKeys.removeAll { $0 == reference }
        redisHashFieldsByKey.removeValue(forKey: reference)
        redisKeyLoadDiscoveredCount = redisKeys.count
        if redisSidebarSelection == reference {
            redisSidebarSelection = nil
        }
        await rebuildRedisKeyTree()
        lastDeletedRedisKey = reference
        redisKeyDeletionRevision &+= 1
    }

    func renameRedisKey(
        _ reference: RedisKeyReference,
        to proposedName: String
    ) async throws -> RedisKeyReference {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RedisKeyEditError.invalidKeyName }
        guard name != reference.name else { return reference }
        guard !safetyLock.isEnabled else {
            throw RedisKeyEditError.safetyLockEnabled
        }
        let plan = RedisKeyRenamePlan(reference: reference, newName: name)
        let result = try await executeRedisCommand(
            plan.command,
            databaseIndex: reference.databaseIndex
        )
        guard case let .integer(didRename) = result.reply else {
            throw RedisWorkspaceError.invalidReply("RENAMENX")
        }
        guard didRename == 1 else {
            throw RedisKeyEditError.keyAlreadyExists(name)
        }

        let renamed = RedisKeyReference(
            databaseIndex: reference.databaseIndex,
            name: name,
            type: reference.type
        )
        if let index = redisKeys.firstIndex(of: reference) {
            redisKeys[index] = renamed
        }
        if let fields = redisHashFieldsByKey.removeValue(forKey: reference) {
            redisHashFieldsByKey[renamed] = fields
        }
        if redisSidebarSelection == reference {
            redisSidebarSelection = renamed
        }
        await rebuildRedisKeyTree()
        lastRenamedRedisKey = (reference, renamed)
        redisKeyRenameRevision &+= 1
        return renamed
    }

    func loadObjects(in databaseName: String) async {
        guard
            let session,
            connectionState == .connected,
            let index = databases.firstIndex(where: { $0.name == databaseName })
        else {
            return
        }

        switch databases[index].objectsState {
        case .loading, .loaded:
            return
        case .notLoaded, .queued, .failed:
            databases[index].objectsState = .loading
        }
        let requestGeneration = nextObjectRequestGeneration(
            for: databaseName
        )

        do {
            let objects = try await sessionOperationGate.run {
                try await session.fetchObjects(in: databaseName)
            }
            try Task.checkCancellation()
            guard
                self.session === session,
                objectRequestGenerations[databaseName] == requestGeneration,
                let updatedIndex = databases.firstIndex(
                    where: { $0.name == databaseName }
                )
            else {
                return
            }
            databases[updatedIndex].objectsState = .loaded(objects)
            mergeAvailableSchemas(from: objects)
        } catch is CancellationError {
            if self.session === session,
               objectRequestGenerations[databaseName] == requestGeneration
            {
                setObjectsState(.notLoaded, for: databaseName)
            }
        } catch {
            if objectRequestGenerations[databaseName] == requestGeneration {
                setObjectsState(
                    .failed(error.localizedDescription),
                    for: databaseName
                )
            }
        }
    }

    @discardableResult
    func refreshObjects(in databaseName: String) async -> Bool {
        guard
            let session,
            connectionState == .connected,
            databases.contains(where: { $0.name == databaseName })
        else {
            return false
        }

        let requestGeneration = nextObjectRequestGeneration(
            for: databaseName
        )
        do {
            let objects = try await sessionOperationGate.run {
                try await session.fetchObjects(in: databaseName)
            }
            try Task.checkCancellation()
            guard
                self.session === session,
                objectRequestGenerations[databaseName] == requestGeneration,
                let index = databases.firstIndex(
                    where: { $0.name == databaseName }
                )
            else {
                return false
            }
            databases[index].objectsState = .loaded(objects)
            mergeAvailableSchemas(from: objects)
            return true
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    private func replaceAvailableSchemas(_ names: [String]) {
        guard databaseType == .postgresql else {
            availableSchemas = []
            selectedSchema = nil
            return
        }
        let schemas = Array(Set(names)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        availableSchemas = schemas
        if let selectedSchema, schemas.contains(selectedSchema) {
            return
        }
        selectedSchema = schemas.contains("public") ? "public" : schemas.first
    }

    private func mergeAvailableSchemas(
        from objects: [WorkspaceDatabaseObject]
    ) {
        guard databaseType == .postgresql else { return }
        replaceAvailableSchemas(
            availableSchemas + objects.compactMap(\.schemaName)
        )
    }

    private func close(_ session: any WorkspaceSession) async {
        if self.session === session {
            cancelObjectLoads()
            redisKeyLoadTask?.cancel()
            redisKeyLoadTask = nil
            await schemaCatalogCoordinator.disconnect()
            for document in queryDocuments {
                await document.closeForWorkspaceShutdown()
            }
            if let dataSession {
                self.dataSession = nil
                dataLoadID = nil
                dataLoadSelection = nil
                clearDataReplacement()
                await dataSession.close()
            }
            if let dataCountSession {
                self.dataCountSession = nil
                dataCountLoadID = nil
                dataCountLoadSelection = nil
                await dataCountSession.close()
            }
            sessionConfiguration = nil
            availableSchemas = []
            selectedSchema = nil
            redisLogicalDatabases = []
            redisKeys = []
            redisKeyTree = []
            redisHashFieldsByKey = [:]
            redisSidebarSelection = nil
        }
        await sessionOperationGate.runUncancelled {
            await session.close()
        }
        if self.session === session {
            self.session = nil
            sessionCapabilities = .standard
        }
    }

    private func startObjectLoaderIfNeeded() {
        guard objectLoadingTask == nil else { return }

        let generation = objectLoadGeneration
        objectLoadingTask = Task { [weak self] in
            await self?.processObjectLoadQueue(generation: generation)
        }
    }

    func refreshSchemaCatalog() async {
        guard connectionState == .connected,
              let sessionConfiguration
        else {
            return
        }
        await schemaCatalogCoordinator.refresh(
            configuration: sessionConfiguration
        )
    }

    func prepareCompletionColumns(
        for objects: [WorkspaceSchemaObjectReference]
    ) async -> WorkspaceSchemaCatalogSnapshot {
        guard connectionState == .connected else { return schemaCatalog }
        return await schemaCatalogCoordinator.prepareColumns(for: objects)
    }

    func invalidateCompletionColumns() {
        schemaCatalogCoordinator.invalidateActiveRelationColumns()
    }

    private func processObjectLoadQueue(generation: Int) async {
        defer {
            if objectLoadGeneration == generation {
                objectLoadingTask = nil
            }
        }

        while
            !Task.isCancelled,
            objectLoadGeneration == generation,
            !objectLoadQueue.isEmpty
        {
            let databaseName = objectLoadQueue.removeFirst()
            await loadObjects(in: databaseName)
        }
    }

    private func cancelObjectLoads() {
        objectLoadGeneration += 1
        objectLoadingTask?.cancel()
        objectLoadingTask = nil
        for load in elasticsearchCompletionFieldLoads.values {
            load.task.cancel()
        }
        elasticsearchCompletionFieldLoads.removeAll()
        dataCountTask?.cancel()
        dataCountTask = nil
        dataCountLoadID = nil
        dataCountLoadSelection = nil
        clearDataReplacement()
        objectLoadQueue.removeAll()

        for index in databases.indices {
            switch databases[index].objectsState {
            case .queued, .loading:
                databases[index].objectsState = .notLoaded
            case .notLoaded, .loaded, .failed:
                break
            }
        }

        let loadingSelections = objectDetailsStates.compactMap { selection, state in
            state == .loading ? selection : nil
        }
        for selection in loadingSelections {
            objectDetailsStates[selection] = .notLoaded
        }

        let loadingIndexSelections = objectIndexesStates.compactMap {
            selection,
            state in
            state == .loading ? selection : nil
        }
        for selection in loadingIndexSelections {
            objectIndexesStates[selection] = .notLoaded
        }

        let loadingDataSelections = objectDataStates.compactMap { selection, state in
            switch state {
            case .loading, .fetching:
                selection
            case .notLoaded, .stopped, .loaded, .failed:
                nil
            }
        }
        for selection in loadingDataSelections {
            objectDataStates[selection] = .notLoaded
        }
        objectDataOffsets.removeAll()
        objectDataLimits.removeAll()
        objectDataSorts.removeAll()
        objectDataFilters.removeAll()
        objectDataCountFilters.removeAll()

        let loadingCountSelections = objectDataCountStates.compactMap {
            selection,
            state in
            state == .loading ? selection : nil
        }
        for selection in loadingCountSelections {
            objectDataCountStates[selection] = .notLoaded
        }
    }

    private func appendDataBatch(
        _ batch: WorkspaceDatabaseDataBatch,
        for selection: WorkspaceDatabaseObjectSelection,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        filter: WorkspaceDatabaseDataFilter,
        loadID: UUID,
        session: any WorkspaceSession
    ) {
        guard
            !batch.rows.isEmpty,
            self.session === session,
            selectedObject == selection,
            dataLoadID == loadID,
            dataLoadSelection == selection,
            objectDataOffsets[selection] == offset,
            objectDataLimits[selection] == limit,
            objectDataSorts[selection] == sort,
            objectDataFilters[selection] == filter
        else {
            return
        }

        if dataReplacementLoadID == loadID,
           let dataReplacementRowStore
        {
            dataReplacementRowStore.append(batch.rows)
            return
        }

        let rowStore: WorkspaceDatabaseDataRowStore
        let columns: [WorkspaceDatabaseDataColumn]
        switch objectDataStates[selection] ?? .notLoaded {
        case let .fetching(page)
            where page.offset == offset
                && page.limit == limit
                && page.sort == sort
                && page.filter == filter:
            rowStore = page.rowStore
            columns = page.columns
        case .loading, .fetching:
            rowStore = WorkspaceDatabaseDataRowStore()
            columns = batch.columns
        case .notLoaded, .stopped, .loaded, .failed:
            return
        }

        rowStore.append(batch.rows)
        objectDataStates[selection] = .fetching(
            WorkspaceDatabaseDataPage(
                columns: columns,
                rowStore: rowStore,
                offset: offset,
                limit: limit,
                hasNextPage: false,
                sort: sort,
                filter: filter
            )
        )
    }

    private func clearDataReplacement(for loadID: UUID? = nil) {
        if let loadID, dataReplacementLoadID != loadID { return }
        dataReplacementLoadID = nil
        dataReplacementRowStore = nil
    }

    private func connectedDataSession() async throws -> any WorkspaceSession {
        if let dataSession {
            let isConnected = await dataSession.isConnected()
            guard self.dataSession === dataSession else {
                throw CancellationError()
            }
            if isConnected {
                return dataSession
            }
            self.dataSession = nil
            await dataSession.close()
        }
        guard let configuration = sessionConfiguration, session != nil else {
            throw WorkspaceSessionError.notConnected
        }

        let newSession = await sessionFactory.makeSession(
            configuration: configuration
        )
        dataSession = newSession
        do {
            try await newSession.connect()
            try Task.checkCancellation()
        } catch {
            if dataSession === newSession {
                dataSession = nil
            }
            await newSession.close()
            throw error
        }

        guard
            dataSession === newSession,
            sessionConfiguration == configuration,
            session != nil
        else {
            if dataSession === newSession {
                dataSession = nil
            }
            await newSession.close()
            throw CancellationError()
        }

        return newSession
    }

    private func updateDataCount(
        for selection: WorkspaceDatabaseObjectSelection,
        page: WorkspaceDatabaseDataPage,
        filter: WorkspaceDatabaseDataFilter,
        force: Bool
    ) async {
        if
            !page.hasNextPage,
            page.offset == 0 || page.rowCount > 0
        {
            let ownsActiveCount = dataCountLoadSelection == selection
            let countSession = ownsActiveCount ? dataCountSession : nil
            if ownsActiveCount {
                dataCountLoadID = nil
                dataCountLoadSelection = nil
                dataCountTask?.cancel()
                dataCountTask = nil
                dataCountSession = nil
            }
            objectDataCountStates[selection] = .loaded(
                page.offset + page.rowCount
            )
            objectDataCountFilters[selection] = filter
            if let countSession {
                await countSession.close()
            }
            return
        }

        await startDataCountIfNeeded(
            for: selection,
            filter: filter,
            force: force
        )
    }

    private func startDataCountIfNeeded(
        for selection: WorkspaceDatabaseObjectSelection,
        filter: WorkspaceDatabaseDataFilter,
        force: Bool
    ) async {
        if !force, objectDataCountFilters[selection] == filter {
            switch objectDataCountStates[selection] ?? .notLoaded {
            case .loading, .loaded:
                return
            case .notLoaded, .failed:
                break
            }
        }

        guard selectedObject == selection else { return }
        let supersededSelection = dataCountLoadSelection
        let supersededSession = dataCountSession
        dataCountLoadID = nil
        dataCountLoadSelection = nil
        dataCountTask?.cancel()
        dataCountTask = nil
        dataCountSession = nil
        if
            let supersededSelection,
            objectDataCountStates[supersededSelection] == .loading
        {
            objectDataCountStates[supersededSelection] = .notLoaded
        }

        let loadID = UUID()
        dataCountLoadID = loadID
        dataCountLoadSelection = selection
        objectDataCountStates[selection] = .loading
        objectDataCountFilters[selection] = filter
        if let supersededSession {
            await supersededSession.close()
        }
        guard
            selectedObject == selection,
            dataCountLoadID == loadID,
            dataCountLoadSelection == selection,
            objectDataCountFilters[selection] == filter
        else {
            if
                dataCountLoadID == loadID,
                dataCountLoadSelection == selection
            {
                dataCountLoadID = nil
                dataCountLoadSelection = nil
                if objectDataCountStates[selection] == .loading {
                    objectDataCountStates[selection] = .notLoaded
                }
            }
            return
        }
        dataCountTask = Task { [weak self] in
            await self?.loadDataCount(
                for: selection,
                filter: filter,
                loadID: loadID
            )
        }
    }

    private func loadDataCount(
        for selection: WorkspaceDatabaseObjectSelection,
        filter: WorkspaceDatabaseDataFilter,
        loadID: UUID
    ) async {
        defer {
            if
                dataCountLoadID == loadID,
                dataCountLoadSelection == selection
            {
                if objectDataCountStates[selection] == .loading {
                    objectDataCountStates[selection] = .notLoaded
                }
                dataCountLoadID = nil
                dataCountLoadSelection = nil
                dataCountTask = nil
            }
        }
        do {
            let countSession = try await connectedDataCountSession()
            guard
                selectedObject == selection,
                dataCountLoadID == loadID,
                dataCountLoadSelection == selection
            else {
                if dataCountSession === countSession {
                    dataCountSession = nil
                }
                await countSession.close()
                return
            }
            let count = try await countSession.fetchDataCount(
                for: selection.object,
                in: selection.databaseName,
                filter: filter
            )
            try Task.checkCancellation()
            guard
                selectedObject == selection,
                dataCountLoadID == loadID,
                dataCountLoadSelection == selection,
                dataCountSession === countSession,
                objectDataCountFilters[selection] == filter
            else {
                return
            }
            objectDataCountStates[selection] = .loaded(count)
        } catch is CancellationError {
            if
                dataCountLoadID == loadID,
                dataCountLoadSelection == selection,
                objectDataCountStates[selection] == .loading
            {
                objectDataCountStates[selection] = .notLoaded
            }
        } catch {
            guard
                selectedObject == selection,
                dataCountLoadID == loadID,
                dataCountLoadSelection == selection
            else {
                return
            }
            objectDataCountStates[selection] = .failed
        }

    }

    private func connectedDataCountSession() async throws
        -> any WorkspaceSession
    {
        if let dataCountSession {
            let isConnected = await dataCountSession.isConnected()
            guard self.dataCountSession === dataCountSession else {
                throw CancellationError()
            }
            if isConnected {
                return dataCountSession
            }
            self.dataCountSession = nil
            await dataCountSession.close()
        }
        guard let configuration = sessionConfiguration, session != nil else {
            throw WorkspaceSessionError.notConnected
        }

        let newSession = await sessionFactory.makeSession(
            configuration: configuration
        )
        do {
            try await newSession.connect()
            try Task.checkCancellation()
        } catch {
            await newSession.close()
            throw error
        }

        guard
            sessionConfiguration == configuration,
            session != nil
        else {
            await newSession.close()
            throw CancellationError()
        }

        dataCountSession = newSession
        return newSession
    }

    private func setObjectsState(
        _ state: WorkspaceDatabaseObjectsState,
        for databaseName: String
    ) {
        guard let index = databases.firstIndex(
            where: { $0.name == databaseName }
        ) else {
            return
        }
        databases[index].objectsState = state
    }

    private func nextObjectRequestGeneration(
        for databaseName: String
    ) -> Int {
        objectRequestGenerations[databaseName, default: 0] += 1
        return objectRequestGenerations[databaseName, default: 0]
    }

    private func makeDatabases(
        from names: [String],
        preserving existingDatabases: [WorkspaceDatabase] = []
    ) -> [WorkspaceDatabase] {
        let existingByName = Dictionary(
            uniqueKeysWithValues: existingDatabases.map { ($0.name, $0) }
        )
        return Set(names).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map { name in
            existingByName[name] ?? WorkspaceDatabase(name: name)
        }
    }

    private func reloadSavedQueries() async {
        _ = await refreshSavedQueriesFromRepository()
    }

    private var recoverableContentDidChange: @MainActor (UUID) -> Void {
        { [weak self] documentID in
            self?.scheduleRecoverableDraftUpdate(for: documentID)
        }
    }

    private func recoverDraftsIfNeeded(
        configuration: DatabaseConnectionConfiguration
    ) async -> Bool {
        guard !didRecoverDrafts, !isRecoveringDrafts else { return false }
        isRecoveringDrafts = true
        defer { isRecoveringDrafts = false }

        do {
            let drafts = if let initialRestorationState {
                try await recoverableDraftRepository.fetchAll(
                    workspaceID: initialRestorationState.id
                )
            } else {
                try await recoverableDraftRepository.fetchAll(
                    connectionProfileID: profileID
                )
            }
            guard !didRecoverDrafts else { return false }
            didRecoverDrafts = true

            var recoveredNumber = 1
            var didRecoverDocument = false
            var restoredDocumentIDs: Set<UUID> = []

            if let initialRestorationState {
                let draftsByID = Dictionary(
                    uniqueKeysWithValues: drafts.map { ($0.id, $0) }
                )
                for state in initialRestorationState.selectedDatabaseContext
                    .queryDocuments
                {
                    let document: WorkspaceQueryDocumentModel?
                    if let draft = draftsByID[state.id] {
                        document = makeRecoveredDocument(
                            draft,
                            title: state.title,
                            configuration: configuration,
                            resultRowLimit: state.resultRowLimit
                        )
                    } else if let savedQueryID = state.savedQueryID,
                              let savedQuery = savedQueries.first(where: {
                                  $0.id == savedQueryID
                              })
                    {
                        document = WorkspaceQueryDocumentModel(
                            id: state.id,
                            title: savedQuery.name,
                            configuration: configuration,
                            sessionFactory: sessionFactory,
                            savedQuery: savedQuery,
                            resultRowLimit: state.resultRowLimit,
                            recoverableContentDidChange:
                                recoverableContentDidChange
                        )
                    } else if state.savedQueryID == nil {
                        document = WorkspaceQueryDocumentModel(
                            id: state.id,
                            title: state.title,
                            configuration: configuration,
                            sessionFactory: sessionFactory,
                            restorationState: state,
                            recoverableContentDidChange:
                                recoverableContentDidChange
                        )
                    } else {
                        document = nil
                    }

                    guard let document else { continue }
                    queryDocuments.append(document)
                    restoredDocumentIDs.insert(document.id)
                    didRecoverDocument = true
                }
            }

            for draft in drafts
            where recoversUnassignedDrafts
                && !restoredDocumentIDs.contains(draft.id)
                && !excludedRecoverableDraftIDs.contains(draft.id)
            {
                let document = WorkspaceQueryDocumentModel(
                    title: AppCopy.current.text(
                        "已恢复查询 \(recoveredNumber)",
                        "Recovered Query \(recoveredNumber)"
                    ),
                    configuration: configuration,
                    sessionFactory: sessionFactory,
                    recoverableDraft: draft,
                    recoverableContentDidChange: recoverableContentDidChange
                )
                recoverableDraftCreatedAt[draft.id] = draft.createdAt
                queryDocuments.append(document)
                selectedQueryDocumentID = document.id
                recoveredNumber += 1
                didRecoverDocument = true
            }

            if let selectedID =
                initialRestorationState?.selectedDatabaseContext
                    .selectedQueryDocumentID,
               queryDocuments.contains(where: { $0.id == selectedID })
            {
                selectedQueryDocumentID = selectedID
            } else if didRecoverDocument {
                selectedQueryDocumentID = queryDocuments.last?.id
            }
            nextQueryDocumentNumber = max(
                nextQueryDocumentNumber,
                queryDocuments.count + 1
            )
            return didRecoverDocument
        } catch is CancellationError {
            return false
        } catch {
            reportRecoverableDraftError(error)
            return false
        }
    }

    private func makeRecoveredDocument(
        _ draft: RecoverableDraft,
        title: String,
        configuration: DatabaseConnectionConfiguration,
        resultRowLimit: QueryResultRowLimit? = nil
    ) -> WorkspaceQueryDocumentModel {
        recoverableDraftCreatedAt[draft.id] = draft.createdAt
        return WorkspaceQueryDocumentModel(
            title: title,
            configuration: configuration,
            sessionFactory: sessionFactory,
            recoverableDraft: draft,
            resultRowLimit: resultRowLimit,
            recoverableContentDidChange: recoverableContentDidChange
        )
    }

    private func restoreSelectedObjectIfAvailable() async {
        guard let selection = restoredSelectedObject else { return }
        guard databases.contains(where: {
            $0.name == selection.databaseName
        }) else {
            restoredSelectedObject = nil
            return
        }

        await loadObjects(in: selection.databaseName)
        guard restoredSelectedObject == selection,
              let database = databases.first(where: {
            $0.name == selection.databaseName
        }),
        case let .loaded(objects) = database.objectsState,
        objects.contains(where: {
            $0.name == selection.objectName && $0.kind == selection.kind
        }) else {
            restoredSelectedObject = nil
            return
        }

        selectedQueryDocumentID = nil
        selectedObject = selection
        restoredSelectedObject = nil
    }

    private func scheduleRecoverableDraftUpdate(for documentID: UUID) {
        recoverableDraftGenerations[documentID, default: 0] += 1
        let generation = recoverableDraftGenerations[documentID, default: 0]
        recoverableDraftTasks[documentID]?.cancel()
        let delay = recoverableDraftSaveDelay

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
            } catch is CancellationError {
                finishRecoverableDraftTask(
                    for: documentID,
                    generation: generation
                )
                return
            } catch {
                finishRecoverableDraftTask(
                    for: documentID,
                    generation: generation
                )
                return
            }

            await persistRecoverableDraft(
                for: documentID,
                generation: generation
            )
            finishRecoverableDraftTask(
                for: documentID,
                generation: generation
            )
        }
        recoverableDraftTasks[documentID] = task
    }

    private func persistRecoverableDraft(
        for documentID: UUID,
        generation: Int
    ) async {
        guard recoverableDraftGenerations[documentID] == generation,
              let document = queryDocuments.first(where: {
                  $0.id == documentID
              })
        else {
            return
        }

        guard document.isDirty else {
            do {
                try await recoverableDraftRepository.delete(id: documentID)
                recoverableDraftCreatedAt[documentID] = nil
            } catch is CancellationError {
                return
            } catch {
                reportRecoverableDraftError(error)
            }
            return
        }

        let now = Date.now
        let createdAt = recoverableDraftCreatedAt[documentID] ?? now
        recoverableDraftCreatedAt[documentID] = createdAt
        let draft = RecoverableDraft(
            id: document.id,
            workspaceID: workspaceID,
            connectionProfileID: profileID,
            defaultDatabase: document.databaseName,
            sql: document.sql,
            createdAt: createdAt,
            updatedAt: now
        )

        do {
            try await recoverableDraftRepository.save(draft)
        } catch is CancellationError {
            return
        } catch {
            guard recoverableDraftGenerations[documentID] == generation else {
                return
            }
            reportRecoverableDraftError(error)
        }
    }

    private func finishRecoverableDraftTask(
        for documentID: UUID,
        generation: Int
    ) {
        guard recoverableDraftGenerations[documentID] == generation else {
            return
        }
        recoverableDraftTasks[documentID] = nil
    }

    private func reportRecoverableDraftError(_ error: any Error) {
        recoverableDraftErrorMessage = error.localizedDescription
        isShowingRecoverableDraftError = true
    }

    func reportWorkspaceRestorationError(_ error: any Error) {
        workspaceRestorationErrorMessage = error.localizedDescription
        isShowingWorkspaceRestorationError = true
    }

    private func beginSavedQueryMutation(
        _ savedQueryID: SavedQuery.ID
    ) throws -> SavedQuery {
        guard !savedQueryMutationIDs.contains(savedQueryID) else {
            throw WorkspaceSavedQueryError.operationInProgress
        }
        guard let query = savedQuery(id: savedQueryID) else {
            throw WorkspaceSavedQueryError.queryNotFound
        }
        guard queryDocuments.first(where: {
            $0.savedQueryID == savedQueryID
        })?.isSaving != true else {
            throw WorkspaceSavedQueryError.saveInProgress
        }
        savedQueryMutationIDs.insert(savedQueryID)
        savedQueryRevision += 1
        return query
    }

    private func finishSavedQueryMutation(_ query: SavedQuery) {
        if let index = savedQueries.firstIndex(where: { $0.id == query.id }) {
            savedQueries[index] = query
        } else {
            savedQueries.append(query)
        }
        savedQueries.sort(by: Self.savedQueryDisplayOrder)
        savedQueryLoadErrorMessage = nil
        queryDocuments.first {
            $0.savedQueryID == query.id
        }?.applySavedQueryMetadata(query)
    }

    private func savedQueryMatchesSearch(_ query: SavedQuery) -> Bool {
        searchText.isEmpty
            || query.name.localizedCaseInsensitiveContains(searchText)
    }

    private static func savedQueryDisplayOrder(
        _ left: SavedQuery,
        _ right: SavedQuery
    ) -> Bool {
        switch (left.defaultDatabase, right.defaultDatabase) {
        case (nil, nil):
            break
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (leftDatabase?, rightDatabase?):
            let order = leftDatabase.localizedStandardCompare(rightDatabase)
            if order != .orderedSame {
                return order == .orderedAscending
            }
        }

        let nameOrder = left.name.localizedStandardCompare(right.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        if left.createdAt != right.createdAt {
            return left.createdAt < right.createdAt
        }
        return left.id.uuidString < right.id.uuidString
    }

    static func makeDefault(
        profileID: ConnectionProfile.ID,
        workspaceID: UUID = UUID(),
        restorationState: WorkspaceRestorationState? = nil,
        databaseContextName: String? = nil,
        recoversUnassignedDrafts: Bool = true,
        excludedRecoverableDraftIDs: Set<UUID> = [],
        safetyLock: WorkspaceSafetyLock? = nil,
        workspacePassword: String? = nil
    ) -> WorkspaceModel {
        if ProcessInfo.processInfo.environment["QUERYCRAFT_UI_TESTING"] == "1" {
            return WorkspaceModel(
                profileID: profileID,
                workspaceID: workspaceID,
                repository: InMemoryConnectionProfileRepository(
                    profiles: QueryCraftUITestFixtures.profiles
                ),
                restorationState: restorationState,
                databaseContextName: databaseContextName,
                safetyLock: safetyLock,
                recoversUnassignedDrafts: recoversUnassignedDrafts,
                excludedRecoverableDraftIDs: excludedRecoverableDraftIDs,
                credentialStore: InMemoryCredentialStore(),
                workspacePassword: workspacePassword,
                sessionFactory: InMemoryWorkspaceSessionFactory(
                    databases: ["app_database", "mysql"],
                    objectsByDatabase: [
                        "app_database": [
                            WorkspaceDatabaseObject(name: "users", kind: .table),
                            WorkspaceDatabaseObject(name: "active_users", kind: .view),
                        ]
                    ],
                    detailsByObject: QueryCraftUITestFixtures.objectDetails,
                    indexesByObject: QueryCraftUITestFixtures.objectIndexes,
                    dataByObject: QueryCraftUITestFixtures.objectData
                )
            )
        }

        return WorkspaceModel(
            profileID: profileID,
            workspaceID: workspaceID,
            repository: SQLiteConnectionProfileRepository(),
            savedQueryRepository: SQLiteSavedQueryRepository(),
            recoverableDraftRepository: SQLiteRecoverableDraftRepository(),
            restorationState: restorationState,
            databaseContextName: databaseContextName,
            safetyLock: safetyLock,
            recoversUnassignedDrafts: recoversUnassignedDrafts,
            excludedRecoverableDraftIDs: excludedRecoverableDraftIDs,
            credentialStore: KeychainCredentialStore(),
            workspacePassword: workspacePassword,
            sessionFactory: DefaultWorkspaceSessionFactory()
        )
    }
}
