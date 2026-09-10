import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceSchemaCatalogCoordinator {
    private(set) var snapshot = WorkspaceSchemaCatalogSnapshot.empty

    private let sessionFactory: any WorkspaceSessionFactory
    private var activeConfiguration: DatabaseConnectionConfiguration?
    private var catalogSession: (any WorkspaceSession)?
    private var catalogGeneration = 0
    private var relationColumnGeneration = 0
    private var snapshotRevision: UInt64 = 0
    private var objectCatalog: [WorkspaceSchemaDatabase] = []
    private var activeRelationColumns: [
        WorkspaceSchemaObjectReference: [WorkspaceSchemaColumn]
    ] = [:]
    private var activeRelationObjects: Set<WorkspaceSchemaObjectReference> = []
    private var relationColumnLoadIDs: [WorkspaceSchemaObjectReference: UUID] = [:]
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var relationColumnLoadTasks: [
        UUID: Task<Void, Never>
    ] = [:]

    init(sessionFactory: any WorkspaceSessionFactory) {
        self.sessionFactory = sessionFactory
    }

    func seedDatabases(_ names: [String]) {
        replaceObjectCatalog(
            names.map { WorkspaceSchemaDatabase(name: $0, objects: []) }
        )
    }

    @discardableResult
    func startRefresh(
        configuration: DatabaseConnectionConfiguration
    ) async -> Task<Void, Never> {
        await cancelWork()
        activeConfiguration = configuration
        publishSnapshot()

        let generation = catalogGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.catalogGeneration == generation {
                    self.catalogTask = nil
                }
            }
            do {
                guard let catalogSession = await self.sessionFactory
                    .makeSchemaCatalogSession(configuration: configuration)
                else {
                    return
                }
                do {
                    try await catalogSession.connect()
                    try Task.checkCancellation()
                    let databases = try await catalogSession
                        .fetchSchemaObjectCatalog()
                    try Task.checkCancellation()
                    guard self.catalogGeneration == generation,
                          self.activeConfiguration == configuration
                    else {
                        await catalogSession.close()
                        return
                    }
                    self.catalogSession = catalogSession
                    self.replaceObjectCatalog(databases)
                } catch {
                    await catalogSession.close()
                    throw error
                }
            } catch is CancellationError {
                return
            } catch {
                // Metadata availability is incomplete knowledge, not a connection failure.
                return
            }
        }
        catalogTask = task
        return task
    }

    func refresh(configuration: DatabaseConnectionConfiguration) async {
        let task = await startRefresh(configuration: configuration)
        await task.value
    }

    func prepareColumns(
        for requestedObjects: [WorkspaceSchemaObjectReference]
    ) async -> WorkspaceSchemaCatalogSnapshot {
        guard let catalogSession else { return snapshot }

        let objects = Array(
            Set(requestedObjects.compactMap(catalogReference(for:)))
        )
        let requestedSet = Set(objects)
        activeRelationObjects = requestedSet
        cancelColumnLoads(withoutAnyOf: requestedSet)

        let inactiveObjects = activeRelationColumns.keys.filter {
            !requestedSet.contains($0)
        }
        if !inactiveObjects.isEmpty {
            for object in inactiveObjects {
                activeRelationColumns[object] = nil
            }
            publishSnapshot()
        }

        guard !objects.isEmpty else { return snapshot }

        var taskIDs: Set<UUID> = []
        var missing: [WorkspaceSchemaObjectReference] = []
        for object in objects {
            if activeRelationColumns[object] != nil {
                continue
            } else if let loadID = relationColumnLoadIDs[object] {
                taskIDs.insert(loadID)
            } else {
                missing.append(object)
            }
        }

        if !missing.isEmpty {
            let loadID = UUID()
            let catalogGeneration = catalogGeneration
            let columnGeneration = relationColumnGeneration
            let task = Task { [weak self] in
                guard let self else { return }
                await self.performColumnLoad(
                    missing,
                    loadID: loadID,
                    catalogGeneration: catalogGeneration,
                    columnGeneration: columnGeneration,
                    catalogSession: catalogSession
                )
            }
            relationColumnLoadTasks[loadID] = task
            for object in missing {
                relationColumnLoadIDs[object] = loadID
            }
            taskIDs.insert(loadID)
        }

        let tasks = taskIDs.compactMap { relationColumnLoadTasks[$0] }
        for task in tasks {
            await task.value
        }
        return snapshot
    }

    func invalidateActiveRelationColumns() {
        relationColumnGeneration += 1
        let tasks = Array(relationColumnLoadTasks.values)
        relationColumnLoadTasks.removeAll()
        relationColumnLoadIDs.removeAll()
        for task in tasks {
            task.cancel()
        }

        activeRelationObjects.removeAll()
        guard !activeRelationColumns.isEmpty else { return }
        activeRelationColumns.removeAll()
        publishSnapshot()
    }

    func disconnect() async {
        await cancelWork()
        replaceObjectCatalog([])
    }

    private func cancelWork() async {
        catalogGeneration += 1
        relationColumnGeneration += 1
        activeConfiguration = nil

        let catalogTask = catalogTask
        self.catalogTask = nil
        catalogTask?.cancel()

        let columnTasks = Array(relationColumnLoadTasks.values)
        relationColumnLoadTasks.removeAll()
        relationColumnLoadIDs.removeAll()
        for task in columnTasks {
            task.cancel()
        }

        activeRelationColumns.removeAll()
        activeRelationObjects.removeAll()

        if let catalogSession {
            self.catalogSession = nil
            await catalogSession.close()
        }
        await catalogTask?.value
        for task in columnTasks {
            await task.value
        }
    }

    private func cancelColumnLoads(
        withoutAnyOf requestedObjects: Set<WorkspaceSchemaObjectReference>
    ) {
        let retainedLoadIDs = Set(
            relationColumnLoadIDs.compactMap { object, loadID in
                requestedObjects.contains(object) ? loadID : nil
            }
        )
        let cancelledLoadIDs = Set(relationColumnLoadTasks.keys)
            .subtracting(retainedLoadIDs)
        for loadID in cancelledLoadIDs {
            relationColumnLoadTasks.removeValue(forKey: loadID)?.cancel()
        }
        relationColumnLoadIDs = relationColumnLoadIDs.filter {
            requestedObjects.contains($0.key)
        }
    }

    private func replaceObjectCatalog(_ databases: [WorkspaceSchemaDatabase]) {
        objectCatalog = databases.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        publishSnapshot()
    }

    private func publishSnapshot() {
        snapshotRevision += 1
        snapshot = WorkspaceSchemaCatalogSnapshot(
            revision: snapshotRevision,
            databases: objectCatalog.map { database in
                WorkspaceSchemaDatabase(
                    name: database.name,
                    objects: database.objects.map { object in
                        let reference = WorkspaceSchemaObjectReference(
                            databaseName: database.name,
                            objectName: object.name
                        )
                        return WorkspaceSchemaObject(
                            name: object.name,
                            kind: object.kind,
                            columns: activeRelationColumns[reference] ?? []
                        )
                    }
                )
            },
            loadedColumnObjects: Set(activeRelationColumns.keys)
        )
    }

    private func performColumnLoad(
        _ objects: [WorkspaceSchemaObjectReference],
        loadID: UUID,
        catalogGeneration: Int,
        columnGeneration: Int,
        catalogSession: any WorkspaceSession
    ) async {
        defer {
            relationColumnLoadTasks[loadID] = nil
            for object in objects where relationColumnLoadIDs[object] == loadID {
                relationColumnLoadIDs[object] = nil
            }
        }

        do {
            let results = try await catalogSession.fetchSchemaColumns(for: objects)
            try Task.checkCancellation()
            guard self.catalogGeneration == catalogGeneration,
                  relationColumnGeneration == columnGeneration,
                  self.catalogSession === catalogSession
            else {
                return
            }

            let columnsByObject = Dictionary(
                uniqueKeysWithValues: results.map { ($0.reference, $0.columns) }
            )
            let activeObjects = objects.filter(activeRelationObjects.contains)
            guard !activeObjects.isEmpty else { return }
            for object in activeObjects {
                activeRelationColumns[object] = columnsByObject[object] ?? []
            }
            publishSnapshot()
        } catch is CancellationError {
            return
        } catch {
            guard self.catalogGeneration == catalogGeneration,
                  relationColumnGeneration == columnGeneration,
                  self.catalogSession === catalogSession
            else {
                return
            }
            let activeObjects = objects.filter(activeRelationObjects.contains)
            guard !activeObjects.isEmpty else { return }
            for object in activeObjects {
                activeRelationColumns[object] = []
            }
            publishSnapshot()
        }
    }

    private func catalogReference(
        for requested: WorkspaceSchemaObjectReference
    ) -> WorkspaceSchemaObjectReference? {
        guard let database = objectCatalog.first(where: {
            $0.name.caseInsensitiveCompare(requested.databaseName) == .orderedSame
        }), let object = database.object(named: requested.objectName) else {
            return nil
        }
        return WorkspaceSchemaObjectReference(
            databaseName: database.name,
            objectName: object.name
        )
    }
}
