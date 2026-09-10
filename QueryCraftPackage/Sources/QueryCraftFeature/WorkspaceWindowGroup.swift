import AppKit
import Observation

@MainActor
final class WorkspaceWindowGroup {
    private(set) var databaseContexts: [WorkspaceDatabaseContext]
    private var selectedDatabaseContextID: UUID
    private weak var workspaceManager: WorkspaceWindowManager?

    var model: WorkspaceModel { activeDatabaseContext.model }
    var tabsModel: WorkspaceContentTabsModel {
        activeDatabaseContext.tabsModel
    }

    var databaseContextDescriptors: [WorkspaceDatabaseContextDescriptor] {
        databaseContexts.map {
            WorkspaceDatabaseContextDescriptor(
                id: $0.id,
                databaseName: $0.model.databaseContextName,
                connectionState: $0.model.connectionState
            )
        }
    }

    var selectedContextID: UUID { selectedDatabaseContextID }

    private var controller: WorkspaceWindowController?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var connectionGenerations: [UUID: Int] = [:]
    private var documentCloseTasks: [UUID: Task<Void, Never>] = [:]
    private var restorationPersistenceTask: Task<Void, Never>?
    private var restorationSnapshotTask: Task<Void, Never>?
    private var restorationPersistenceGeneration = 0
    private var restorationCleanupTask: Task<Void, Never>?
    private var framePersistenceTask: Task<Void, Never>?
    private var databaseAdoptionTask: Task<Void, Never>?
    private var savedQueryRefreshTask: Task<Void, Never>?
    private var isObservingRestorationState = false
    private var isExplicitlyClosing = false
    private var didRequestRestoredObjectContent = false
    private var latestWindowFrame: WorkspaceWindowFrame?
    private var restoredSelectedObject: WorkspaceDatabaseObjectSelection?
    private let restorationRepository: any WorkspaceRestorationRepository
    private let restorationCreatedAt: Date
    private let initialRestorationState: WorkspaceRestorationState?
    private let didClose: @MainActor (UUID) -> Void
    private let didRequestMoveDatabaseContext: @MainActor (
        WorkspaceWindowGroup,
        UUID
    ) -> Void
    private let automaticConnectionRetryDelay: Duration

    init(
        profileID: ConnectionProfile.ID,
        workspacePassword: String? = nil,
        restorationRepository: any WorkspaceRestorationRepository =
            SQLiteWorkspaceRestorationRepository(),
        automaticConnectionRetryDelay: Duration = .milliseconds(500),
        workspaceManager: WorkspaceWindowManager? = nil,
        didClose: @escaping @MainActor (UUID) -> Void,
        didRequestMoveDatabaseContext: @escaping @MainActor (
            WorkspaceWindowGroup,
            UUID
        ) -> Void = { _, _ in }
    ) {
        let model = WorkspaceModel.makeDefault(
            profileID: profileID,
            workspacePassword: workspacePassword
        )
        let context = WorkspaceDatabaseContext(model: model)
        databaseContexts = [context]
        selectedDatabaseContextID = context.id
        self.restorationRepository = restorationRepository
        self.automaticConnectionRetryDelay = automaticConnectionRetryDelay
        self.workspaceManager = workspaceManager
        restorationCreatedAt = .now
        initialRestorationState = nil
        self.didClose = didClose
        self.didRequestMoveDatabaseContext = didRequestMoveDatabaseContext
    }

    init(
        model: WorkspaceModel,
        restorationRepository: any WorkspaceRestorationRepository =
            InMemoryWorkspaceRestorationRepository(),
        automaticConnectionRetryDelay: Duration = .milliseconds(500),
        workspaceManager: WorkspaceWindowManager? = nil,
        didClose: @escaping @MainActor (UUID) -> Void,
        didRequestMoveDatabaseContext: @escaping @MainActor (
            WorkspaceWindowGroup,
            UUID
        ) -> Void = { _, _ in }
    ) {
        let context = WorkspaceDatabaseContext(model: model)
        databaseContexts = [context]
        selectedDatabaseContextID = context.id
        self.restorationRepository = restorationRepository
        self.automaticConnectionRetryDelay = automaticConnectionRetryDelay
        self.workspaceManager = workspaceManager
        restorationCreatedAt =
            model.workspaceRestorationState?.createdAt ?? .now
        initialRestorationState = model.workspaceRestorationState
        latestWindowFrame = model.workspaceRestorationState?.windowFrame
        restoredSelectedObject =
            model.workspaceRestorationState?.selectedDatabaseContext
                .selectedObject
        self.didClose = didClose
        self.didRequestMoveDatabaseContext = didRequestMoveDatabaseContext
    }

    init(
        restorationState: WorkspaceRestorationState,
        workspacePassword: String? = nil,
        restorationRepository: any WorkspaceRestorationRepository =
            SQLiteWorkspaceRestorationRepository(),
        automaticConnectionRetryDelay: Duration = .milliseconds(500),
        workspaceManager: WorkspaceWindowManager? = nil,
        didClose: @escaping @MainActor (UUID) -> Void,
        didRequestMoveDatabaseContext: @escaping @MainActor (
            WorkspaceWindowGroup,
            UUID
        ) -> Void = { _, _ in }
    ) {
        let selectedContextID = restorationState.selectedDatabaseContextID
        let safetyLock = WorkspaceSafetyLock()
        let allRestoredDocumentIDs = Set(
            restorationState.databaseContexts.flatMap {
                $0.queryDocuments.map(\.id)
            }
        )
        databaseContexts = restorationState.databaseContexts.map { state in
            let contextRestoration = Self.makeRestorationState(
                for: state,
                parent: restorationState
            )
            let model = WorkspaceModel.makeDefault(
                profileID: restorationState.connectionProfileID,
                workspaceID: restorationState.id,
                restorationState: contextRestoration,
                databaseContextName: state.databaseName,
                recoversUnassignedDrafts: state.id == selectedContextID,
                excludedRecoverableDraftIDs:
                    allRestoredDocumentIDs.subtracting(
                        state.queryDocuments.map(\.id)
                    ),
                safetyLock: safetyLock,
                workspacePassword: workspacePassword
            )
            model.sidebarMode = state.sidebarMode
            return WorkspaceDatabaseContext(
                id: state.id,
                model: model
            )
        }
        if databaseContexts.contains(where: { $0.id == selectedContextID }) {
            selectedDatabaseContextID = selectedContextID
        } else {
            selectedDatabaseContextID = databaseContexts[0].id
        }
        self.restorationRepository = restorationRepository
        self.automaticConnectionRetryDelay = automaticConnectionRetryDelay
        self.workspaceManager = workspaceManager
        restorationCreatedAt = restorationState.createdAt
        initialRestorationState = restorationState
        latestWindowFrame = restorationState.windowFrame
        restoredSelectedObject = restorationState.selectedDatabaseContext
            .selectedObject
        self.didClose = didClose
        self.didRequestMoveDatabaseContext = didRequestMoveDatabaseContext
    }

    init(
        transferredContext: WorkspaceDatabaseContext,
        connectionTask: Task<Void, Never>?,
        restorationRepository: any WorkspaceRestorationRepository,
        automaticConnectionRetryDelay: Duration = .milliseconds(500),
        workspaceManager: WorkspaceWindowManager? = nil,
        didClose: @escaping @MainActor (UUID) -> Void,
        didRequestMoveDatabaseContext: @escaping @MainActor (
            WorkspaceWindowGroup,
            UUID
        ) -> Void
    ) {
        databaseContexts = [transferredContext]
        selectedDatabaseContextID = transferredContext.id
        self.restorationRepository = restorationRepository
        self.automaticConnectionRetryDelay = automaticConnectionRetryDelay
        self.workspaceManager = workspaceManager
        restorationCreatedAt = .now
        initialRestorationState = nil
        restoredSelectedObject = transferredContext.model.selectedObject
        self.didClose = didClose
        self.didRequestMoveDatabaseContext = didRequestMoveDatabaseContext
        if let connectionTask {
            connectionTasks[transferredContext.id] = connectionTask
        }
    }

    var activeWindow: NSWindow? {
        controller?.window
    }

    var activeDatabaseContext: WorkspaceDatabaseContext {
        databaseContexts.first { $0.id == selectedDatabaseContextID }
            ?? databaseContexts[0]
    }

    func open() {
        guard controller == nil else {
            activeWindow?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = WorkspaceWindowController(
            workspaceGroup: self,
            model: model,
            tabsModel: tabsModel,
            initialFrame: latestWindowFrame.map(Self.appKitFrame),
            workspaceManager: workspaceManager ?? .shared
        )
        self.controller = controller
        if let frame = controller.window?.frame {
            latestWindowFrame = WorkspaceWindowFrame(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            )
        }
        if initialRestorationState == nil {
            startObservingRestorationState()
            scheduleRestorationPersistence()
        }
        for context in databaseContexts where connectionTasks[context.id] == nil {
            startConnection(context)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func retryConnection() {
        startConnection(activeDatabaseContext)
    }

    func refreshWorkspace() {
        let context = activeDatabaseContext
        Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            let result = await context.model.refreshDatabases()
            guard context.id == self.selectedDatabaseContextID else { return }
            if result == .reconnectRequired {
                self.startConnection(context)
            }
        }
    }

    func openDatabase(_ databaseName: String) {
        if let context = databaseContexts.first(where: {
            $0.model.databaseContextName == databaseName
        }) {
            selectDatabaseContext(context.id)
            return
        }

        if databaseContexts.count == 1,
           activeDatabaseContext.model.databaseContextName == nil
        {
            let context = activeDatabaseContext
            databaseAdoptionTask?.cancel()
            databaseAdoptionTask = Task { @MainActor [weak self] in
                let requiresSessionReconnect = await context.model
                    .adoptDatabaseContext(databaseName)
                guard let self, !Task.isCancelled else { return }
                if requiresSessionReconnect {
                    self.startConnection(context)
                }
                self.controller?.replaceWorkspace()
                self.scheduleRestorationPersistence()
                self.databaseAdoptionTask = nil
            }
            return
        }

        let siblingModel = model.makeSibling(databaseName: databaseName)
        let context = WorkspaceDatabaseContext(model: siblingModel)
        databaseContexts.append(context)
        selectedDatabaseContextID = context.id
        restoredSelectedObject = nil
        controller?.replaceWorkspace()
        startConnection(context)
        scheduleRestorationPersistenceAfterInterfaceUpdate()
    }

    func selectDatabaseContext(_ contextID: UUID) {
        guard contextID != selectedDatabaseContextID,
              let context = databaseContexts.first(where: {
                  $0.id == contextID
              })
        else {
            return
        }
        selectedDatabaseContextID = contextID
        restoredSelectedObject = context.model.selectedObject
        controller?.replaceWorkspace()
        activateSelectedContent()
        scheduleRestorationPersistenceAfterInterfaceUpdate()
        savedQueryRefreshTask?.cancel()
        savedQueryRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let changes = await context.model
                .refreshSavedQueriesFromRepository()
            guard !Task.isCancelled else { return }
            await self.controller?.presentSavedQueryExternalChanges(changes)
            self.savedQueryRefreshTask = nil
        }
    }

    func refreshActiveSavedQueries() async {
        let context = activeDatabaseContext
        let changes = await context.model.refreshSavedQueriesFromRepository()
        guard context.id == selectedDatabaseContextID else { return }
        await controller?.presentSavedQueryExternalChanges(changes)
    }

    private func refreshInactiveSavedQueries() async {
        let activeContextID = selectedDatabaseContextID
        for context in databaseContexts where context.id != activeContextID {
            _ = await context.model.refreshSavedQueriesFromRepository()
        }
    }

    func removeDatabaseContext(_ contextID: UUID) async {
        guard databaseContexts.count > 1,
              let index = databaseContexts.firstIndex(where: {
                  $0.id == contextID
              })
        else {
            return
        }
        let context = databaseContexts[index]
        if let task = connectionTasks.removeValue(forKey: contextID) {
            task.cancel()
            await task.value
        } else {
            await context.model.disconnect()
        }
        databaseContexts.remove(at: index)

        if selectedDatabaseContextID == contextID {
            let replacementIndex = min(index, databaseContexts.count - 1)
            selectedDatabaseContextID = databaseContexts[replacementIndex].id
        }
        controller?.replaceWorkspace()
        activateSelectedContent()
        scheduleRestorationPersistence()
    }

    func requestMoveDatabaseContextToNewWindow(_ contextID: UUID) {
        guard databaseContexts.count > 1 else { return }
        didRequestMoveDatabaseContext(self, contextID)
    }

    func extractDatabaseContext(
        _ contextID: UUID,
        updatesWindow: Bool = true
    ) -> (WorkspaceDatabaseContext, Task<Void, Never>?)? {
        guard databaseContexts.count > 1,
              let index = databaseContexts.firstIndex(where: {
                  $0.id == contextID
              })
        else {
            return nil
        }
        let context = databaseContexts.remove(at: index)
        let connectionTask = connectionTasks.removeValue(forKey: contextID)

        if selectedDatabaseContextID == contextID {
            let replacementIndex = min(index, databaseContexts.count - 1)
            selectedDatabaseContextID = databaseContexts[replacementIndex].id
        }
        if updatesWindow {
            refreshWindowAfterDatabaseContextExtraction()
        }
        return (context, connectionTask)
    }

    func refreshWindowAfterDatabaseContextExtraction() {
        controller?.replaceWorkspace()
        activateSelectedContent()
        scheduleRestorationPersistence()
    }

    func createQueryDocument() {
        if model.databaseType == .redis {
            guard let document = model.createRedisCommandDocument() else {
                return
            }
            restoredSelectedObject = nil
            tabsModel.append(document)
            model.redisSidebarSelection = nil
            return
        }
        if model.databaseType == .elasticsearch {
            guard let document = model.createElasticsearchRequestDocument()
            else { return }
            configureElasticsearchRequestDocument(document)
            restoredSelectedObject = nil
            tabsModel.append(document)
            model.sidebarSelection = nil
            return
        }
        guard let document = model.createQueryDocument() else { return }
        restoredSelectedObject = nil
        let item = makeTabItem(for: document)
        tabsModel.append(item)
        activateEditorAfterTabUpdate(item.editorContext)
    }

    func openDatabaseObject(
        _ selection: WorkspaceDatabaseObjectSelection
    ) {
        restoredSelectedObject = nil
        tabsModel.open(selection)
        model.sidebarSelection = selection
    }

    func openRedisKey(_ reference: RedisKeyReference) {
        restoredSelectedObject = nil
        tabsModel.open(reference)
        model.redisSidebarSelection = reference
        model.sidebarSelection = nil
    }

    func redisKeyDidRename(
        from oldReference: RedisKeyReference,
        to newReference: RedisKeyReference
    ) {
        tabsModel.replaceRedisKey(oldReference, with: newReference)
        if tabsModel.selectedContentID == .redisKey(newReference) {
            model.redisSidebarSelection = newReference
        }
    }

    func createTableDraft(in databaseName: String) {
        restoredSelectedObject = nil
        let draft = WorkspaceNewTableDraft(
            databaseName: databaseName,
            schemaName: model.databaseType == .postgresql
                ? model.selectedSchema
                : nil,
            schemaEditingDescriptor: model.schemaEditingDescriptor,
            didCreate: { [weak self] draftID, selection in
                self?.tableDraftDidCreate(draftID, selection: selection)
            }
        )
        tabsModel.append(draft)
        model.sidebarSelection = nil
    }

    func tableDraftDidCreate(
        _ draftID: UUID,
        selection: WorkspaceDatabaseObjectSelection
    ) {
        tabsModel.replaceNewTable(draftID, with: selection)
        model.sidebarSelection = selection
        scheduleRestorationPersistence()
    }

    func tableDidRename(
        from oldSelection: WorkspaceDatabaseObjectSelection,
        to newSelection: WorkspaceDatabaseObjectSelection
    ) {
        tabsModel.replaceDatabaseObject(oldSelection, with: newSelection)
        if model.selectedObject == oldSelection {
            model.sidebarSelection = newSelection
        }
        scheduleRestorationPersistence()
    }

    func tableDidDelete(_ selection: WorkspaceDatabaseObjectSelection) {
        closeDatabaseObjectTab(selection)
        scheduleRestorationPersistence()
    }

    func openSavedQuery(_ savedQueryID: SavedQuery.ID) {
        if model.databaseType == .elasticsearch {
            if let existing = tabsModel.contentItems.first(where: { item in
                guard case let .elasticsearchRequest(document) = item else {
                    return false
                }
                return document.savedQueryID == savedQueryID
            }) {
                tabsModel.select(existing.id)
                activateSelectedContent()
                return
            }
            guard let document = model.openElasticsearchSavedRequest(
                savedQueryID
            ) else { return }
            configureElasticsearchRequestDocument(document)
            restoredSelectedObject = nil
            tabsModel.append(document)
            model.sidebarSelection = nil
            return
        }
        guard let result = model.openSavedQueryDocument(savedQueryID) else {
            return
        }
        restoredSelectedObject = nil

        let editorContext: WorkspaceQueryEditorContext
        if result.isNewDocument {
            let item = makeTabItem(for: result.document)
            tabsModel.append(item)
            editorContext = item.editorContext
        } else {
            tabsModel.select(result.document.id)
            guard let selectedItem = tabsModel.selectedItem else { return }
            editorContext = selectedItem.editorContext
        }

        if let previousObject = result.previousObject {
            Task {
                await model.stopDataWork(
                    for: previousObject,
                    reason: .leftDataTab
                )
            }
        }
        activateEditorAfterTabUpdate(editorContext)
    }

    func requestSaveQueryDocument(_ documentID: UUID) {
        controller?.requestSaveQueryDocument(documentID)
    }

    func saveQueryDocument(
        _ documentID: UUID,
        name: String?
    ) async throws {
        _ = try await model.saveQueryDocument(documentID, name: name)
        await refreshInactiveSavedQueries()
    }

    func saveElasticsearchRequestDocument(
        _ document: WorkspaceElasticsearchRequestDocumentModel,
        name: String?
    ) async throws {
        _ = try await model.saveElasticsearchRequestDocument(
            document,
            name: name
        )
        await refreshInactiveSavedQueries()
    }

    @discardableResult
    func renameSavedQuery(
        _ savedQueryID: SavedQuery.ID,
        name: String
    ) async throws -> SavedQuery {
        let query = try await model.renameSavedQuery(
            savedQueryID,
            name: name
        )
        await refreshInactiveSavedQueries()
        return query
    }

    @discardableResult
    func duplicateSavedQuery(
        _ savedQueryID: SavedQuery.ID
    ) async throws -> SavedQuery {
        let query = try await model.duplicateSavedQuery(savedQueryID)
        await refreshInactiveSavedQueries()
        return query
    }

    func deleteSavedQuery(_ savedQueryID: SavedQuery.ID) async throws
        -> [UUID]
    {
        let documentIDs = model.queryDocuments.compactMap { document in
            document.savedQueryID == savedQueryID ? document.id : nil
        }
        try await model.deleteSavedQuery(savedQueryID)
        await refreshInactiveSavedQueries()
        return documentIDs
    }

    func selectQueryDocument(_ documentID: UUID) {
        restoredSelectedObject = nil
        tabsModel.select(documentID)
        let previousObject = model.activateQueryDocument(documentID)
        if let previousObject {
            Task {
                await model.stopDataWork(
                    for: previousObject,
                    reason: .leftDataTab
                )
            }
        }
        guard let editorContext = tabsModel.selectedItem?.editorContext else {
            return
        }
        activateEditorAfterTabUpdate(editorContext)
    }

    func selectContent(_ contentID: WorkspaceContentTabID) {
        switch contentID {
        case let .queryDocument(documentID):
            selectQueryDocument(documentID)
        case let .databaseObject(selection):
            restoredSelectedObject = nil
            tabsModel.select(contentID)
            model.sidebarSelection = selection
        case .newTable:
            restoredSelectedObject = nil
            tabsModel.select(contentID)
            model.sidebarSelection = nil
        case let .redisKey(reference):
            restoredSelectedObject = nil
            tabsModel.select(contentID)
            model.redisSidebarSelection = reference
            model.sidebarSelection = nil
        case .redisCommand:
            restoredSelectedObject = nil
            tabsModel.select(contentID)
            model.redisSidebarSelection = nil
            model.sidebarSelection = nil
        case .elasticsearchRequest:
            restoredSelectedObject = nil
            tabsModel.select(contentID)
            model.redisSidebarSelection = nil
            model.sidebarSelection = nil
        }
    }

    func activateSelectedContentAfterClosingTab() {
        activateSelectedContent()
        scheduleRestorationPersistence()
    }

    func closeDatabaseObjectTab(
        _ selection: WorkspaceDatabaseObjectSelection
    ) {
        tabsModel.removeContent(.databaseObject(selection))
        activateSelectedContent()
    }

    func closeQueryDocumentInBackground(
        _ documentID: UUID,
        authorization: WorkspaceQueryDocumentCloseAuthorization = .preservingChanges
    ) -> WorkspaceQueryDocumentCloseResult {
        guard let document = model.queryDocuments.first(where: {
            $0.id == documentID
        }) else {
            return .closed
        }
        if let message = document.preflightCloseFailureMessage {
            return .failed(message: message)
        }
        guard authorization.permitsClosing(document) else {
            return .needsUnsavedChangesDecision
        }
        guard document.transactionState != .inTransaction else {
            return .failed(
                message: AppCopy.current.text(
                    "关闭前必须回滚活动事务。",
                    "An active transaction must be rolled back before closing."
                )
            )
        }
        guard let detachedDocument = model.detachQueryDocument(documentID) else {
            return .closed
        }

        removeTab(documentID)
        let model = model
        let task = Task { @MainActor [weak self, detachedDocument] in
            await model.discardRecoverableDraft(for: documentID)
            _ = await detachedDocument.close()
            self?.documentCloseTasks[documentID] = nil
        }
        documentCloseTasks[documentID] = task
        return .closed
    }

    func closeQueryDocumentAfterRollback(
        _ documentID: UUID,
        authorization: WorkspaceQueryDocumentCloseAuthorization = .preservingChanges
    ) async -> WorkspaceQueryDocumentCloseResult {
        let result = await model.closeQueryDocument(
            documentID,
            authorization: authorization
        )
        guard result == .closed else { return result }
        removeTab(documentID)
        return .closed
    }

    func waitForPendingDocumentClosures() async {
        let tasks = Array(documentCloseTasks.values)
        for task in tasks {
            await task.value
        }
    }

    func restoreRecoveredQueryDocuments(
        in context: WorkspaceDatabaseContext? = nil
    ) async {
        let context = context ?? activeDatabaseContext
        let model = context.model
        let tabsModel = context.tabsModel
        let restorationState = model.workspaceRestorationState?
            .selectedDatabaseContext
        let existingItems = Dictionary(
            uniqueKeysWithValues: tabsModel.items.map { ($0.id, $0) }
        )
        let queryItems = model.queryDocuments.map { document in
            existingItems[document.id] ?? makeTabItem(for: document)
        }
        let existingRequestDocuments: [
            UUID: WorkspaceElasticsearchRequestDocumentModel
        ] = Dictionary(
            uniqueKeysWithValues: tabsModel.contentItems.compactMap {
                item -> (UUID, WorkspaceElasticsearchRequestDocumentModel)? in
                guard case let .elasticsearchRequest(document) = item else {
                    return nil
                }
                return (document.id, document)
            }
        )
        let requestDocuments: [WorkspaceElasticsearchRequestDocumentModel] = (
            restorationState?.elasticsearchRequestDocuments ?? []
        ).compactMap { state in
            existingRequestDocuments[state.id]
                ?? model.restoreElasticsearchRequestDocuments([state]).first
        }
        for document in requestDocuments {
            configureElasticsearchRequestDocument(document)
        }
        let defaultContentOrder: [WorkspaceContentTabID] = queryItems.map {
            .queryDocument($0.id)
        } + requestDocuments.map {
            .elasticsearchRequest($0.id)
        }
        let contentOrder = restorationState?.contentTabOrder
            ?? defaultContentOrder
        let selectedContent = restorationState?.selectedContentTab
            ?? model.selectedQueryDocumentID.map {
                .queryDocument($0)
            }
        tabsModel.restore(
            queryItems: queryItems,
            elasticsearchRequestDocuments: requestDocuments,
            contentOrder: contentOrder,
            selecting: selectedContent
        )
        startObservingRestorationState()
        scheduleRestorationPersistence()
        if context.id == selectedDatabaseContextID,
           (model.connectionState == .connected
                || tabsModel.selectedDocumentID != nil)
        {
            activateSelectedContent()
        }
        if context.id == selectedDatabaseContextID {
            await loadRestoredSelectedObjectContentIfNeeded()
        }
    }

    func requestExplicitClose() async -> Bool {
        guard let controller else { return true }
        guard await controller.requestExplicitClose() else { return false }
        await waitForPendingDocumentClosures()
        await waitForRestorationPersistence()
        return true
    }

    func prepareForExplicitClose() async {
        workspaceWillCloseExplicitly()
        await waitForPendingDocumentClosures()
        scheduleRestorationDeletion()
        await restorationCleanupTask?.value
    }

    func windowControllerDidBecomeKey(_ controller: WorkspaceWindowController) {
        guard self.controller === controller,
              let selectedContentID = tabsModel.selectedContentID
        else {
            return
        }
        selectContent(selectedContentID)
    }

    func windowControllerDidClose(_ controller: WorkspaceWindowController) {
        guard self.controller === controller else { return }
        self.controller = nil
        for task in connectionTasks.values {
            task.cancel()
        }
        connectionTasks.removeAll()
        databaseAdoptionTask?.cancel()
        databaseAdoptionTask = nil
        savedQueryRefreshTask?.cancel()
        savedQueryRefreshTask = nil
        isObservingRestorationState = false
        framePersistenceTask?.cancel()
        framePersistenceTask = nil
        if isExplicitlyClosing {
            scheduleRestorationDeletion()
        } else {
            scheduleRestorationPersistence()
        }
        didClose(model.workspaceID)
    }

    func workspaceWillCloseExplicitly() {
        isExplicitlyClosing = true
        isObservingRestorationState = false
        framePersistenceTask?.cancel()
        framePersistenceTask = nil
    }

    func windowFrameDidChange(_ frame: NSRect, immediately: Bool) {
        latestWindowFrame = WorkspaceWindowFrame(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
        framePersistenceTask?.cancel()
        if immediately {
            scheduleRestorationPersistence()
            return
        }
        framePersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            self?.scheduleRestorationPersistence()
            self?.framePersistenceTask = nil
        }
    }

    func waitForRestorationPersistence() async {
        await framePersistenceTask?.value
        while let task = restorationPersistenceTask {
            let generation = restorationPersistenceGeneration
            await task.value
            guard generation != restorationPersistenceGeneration else {
                break
            }
        }
        await restorationCleanupTask?.value
    }

    private func startConnection(_ context: WorkspaceDatabaseContext) {
        context.model.prepareForConnectionAttempt()
        connectionTasks[context.id]?.cancel()
        connectionGenerations[context.id, default: 0] += 1
        let generation = connectionGenerations[context.id, default: 0]
        let model = context.model
        let retryDelay = automaticConnectionRetryDelay
        connectionTasks[context.id] = Task { [weak self, weak context] in
            for attempt in 0..<2 {
                await model.run { [weak self] in
                    guard let self, let context else { return }
                    await self.restoreRecoveredQueryDocuments(in: context)
                    if context.id == self.selectedDatabaseContextID {
                        self.controller?.replaceWorkspace()
                    }
                }
                guard let self, let context,
                      !Task.isCancelled,
                      self.connectionGenerations[context.id] == generation,
                      case .failed = model.connectionState,
                      attempt == 0
                else {
                    break
                }
                do {
                    try await Task.sleep(for: retryDelay)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.connectionGenerations[context.id] == generation
                else {
                    return
                }
                model.prepareForConnectionAttempt()
            }
            if let self, let context,
               self.connectionGenerations[context.id] == generation
            {
                self.connectionTasks[context.id] = nil
            }
        }
    }

    private static func makeRestorationState(
        for context: WorkspaceDatabaseContextRestorationState,
        parent: WorkspaceRestorationState
    ) -> WorkspaceRestorationState {
        WorkspaceRestorationState(
            id: parent.id,
            connectionProfileID: parent.connectionProfileID,
            databaseContexts: [context],
            selectedDatabaseContextID: context.id,
            windowFrame: parent.windowFrame,
            createdAt: parent.createdAt,
            updatedAt: parent.updatedAt
        )
    }

    private func startObservingRestorationState() {
        guard !isObservingRestorationState else { return }
        isObservingRestorationState = true
        observeRestorationState()
    }

    private func observeRestorationState() {
        guard isObservingRestorationState else { return }
        for context in databaseContexts {
            context.model.openElasticsearchRequestSource = { [weak self, weak context] source in
                guard let self, let context, let document = context.model.createElasticsearchRequestDocument() else { return }
                document.source = source
                self.configureElasticsearchRequestDocument(document)
                context.tabsModel.append(document)
            }
        }
        withObservationTracking {
            _ = selectedDatabaseContextID
            for context in databaseContexts {
                _ = context.model.databaseContextName
                _ = context.model.selectedObject
                _ = context.model.sidebarMode
                _ = context.tabsModel.selectedContentID
                for contentItem in context.tabsModel.contentItems {
                    _ = contentItem.id
                    if case let .query(item) = contentItem {
                        _ = item.document.title
                        _ = item.document.savedQueryID
                        _ = item.document.databaseName
                    } else if case let .elasticsearchRequest(document) =
                        contentItem
                    {
                        _ = document.title
                        _ = document.source
                        _ = document.resultRowLimit
                    }
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isObservingRestorationState else {
                    return
                }
                self.scheduleRestorationPersistence()
                self.observeRestorationState()
            }
        }
    }

    private func scheduleRestorationPersistence() {
        guard !isExplicitlyClosing else { return }
        restorationPersistenceGeneration += 1
        let state = makeRestorationState()
        let pendingTask = restorationPersistenceTask
        let repository = restorationRepository
        restorationPersistenceTask = Task {
            await pendingTask?.value
            do {
                try await repository.save(state)
            } catch {
                model.reportWorkspaceRestorationError(error)
            }
        }
    }

    private func scheduleRestorationPersistenceAfterInterfaceUpdate() {
        restorationSnapshotTask?.cancel()
        restorationSnapshotTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.scheduleRestorationPersistence()
            self.restorationSnapshotTask = nil
        }
    }

    private func scheduleRestorationDeletion() {
        guard restorationCleanupTask == nil else { return }
        let pendingPersistence = restorationPersistenceTask
        let repository = restorationRepository
        let workspaceID = model.workspaceID
        restorationCleanupTask = Task {
            await pendingPersistence?.value
            do {
                try await repository.delete(id: workspaceID)
            } catch {
                // A stale restoration record is harmless and can be closed again.
            }
        }
    }

    private func makeRestorationState() -> WorkspaceRestorationState {
        let contextStates = databaseContexts.map(makeContextRestorationState)
        return WorkspaceRestorationState(
            id: model.workspaceID,
            connectionProfileID: model.profileID,
            databaseContexts: contextStates,
            selectedDatabaseContextID: selectedDatabaseContextID,
            windowFrame: latestWindowFrame,
            createdAt: restorationCreatedAt,
            updatedAt: .now
        )
    }

    private func makeContextRestorationState(
        _ context: WorkspaceDatabaseContext
    ) -> WorkspaceDatabaseContextRestorationState {
        let tabsModel = context.tabsModel
        let documents = tabsModel.items.map { item in
            WorkspaceQueryDocumentRestorationState(
                id: item.id,
                title: item.document.title,
                savedQueryID: item.document.savedQueryID,
                defaultDatabase: item.document.databaseName,
                resultRowLimit: item.document.resultRowLimit
            )
        }
        let requestDocuments: [WorkspaceElasticsearchRequestRestorationState] =
            tabsModel.contentItems.compactMap { item in
            guard case let .elasticsearchRequest(document) = item else {
                return nil
            }
            return document.restorationState
        }
        let restorableContentIDs = tabsModel.contentItems.compactMap { item in
            switch item {
            case .query, .databaseObject, .redisKey, .elasticsearchRequest:
                item.id
            case .newTable, .redisCommand:
                nil
            }
        }
        let selectedRestorableContentID = tabsModel.selectedContentID.flatMap {
            restorableContentIDs.contains($0) ? $0 : restorableContentIDs.last
        }
        return WorkspaceDatabaseContextRestorationState(
            id: context.id,
            databaseName: context.model.databaseContextName,
            selectedObject:
                selectedRestorableContentID?.databaseObjectSelection
                    ?? context.model.selectedObject,
            queryDocuments: documents,
            selectedQueryDocumentID: tabsModel.selectedDocumentID,
            contentTabOrder: restorableContentIDs,
            selectedContentTab: selectedRestorableContentID,
            sidebarMode: context.model.sidebarMode,
            elasticsearchRequestDocuments: requestDocuments
        )
    }

    private static func appKitFrame(
        _ frame: WorkspaceWindowFrame
    ) -> NSRect {
        NSRect(
            x: frame.x,
            y: frame.y,
            width: frame.width,
            height: frame.height
        )
    }

    private func removeTab(_ documentID: UUID) {
        tabsModel.removeContent(.queryDocument(documentID))
        activateSelectedContent()
    }

    private func activateSelectedContent() {
        switch tabsModel.selectedContentID {
        case let .queryDocument(documentID):
            selectQueryDocument(documentID)
        case let .databaseObject(selection):
            model.sidebarSelection = selection
        case .newTable:
            model.sidebarSelection = nil
        case let .redisKey(reference):
            model.redisSidebarSelection = reference
            model.sidebarSelection = nil
        case .redisCommand:
            model.redisSidebarSelection = nil
            model.sidebarSelection = nil
        case .elasticsearchRequest:
            model.redisSidebarSelection = nil
            model.sidebarSelection = nil
        case nil:
            model.redisSidebarSelection = nil
            model.sidebarSelection = nil
        }
    }

    private func loadRestoredSelectedObjectContentIfNeeded() async {
        guard initialRestorationState != nil,
              !didRequestRestoredObjectContent,
              model.connectionState == .connected,
              case let .databaseObject(selection) = tabsModel.selectedContentID,
              model.selectedObject == selection
        else {
            return
        }
        didRequestRestoredObjectContent = true
        async let details: Void = model.loadDetails(for: selection)
        await model.loadData(
            for: selection,
            offset: 0,
            limit: ApplicationPreferences.shared.tableDataPageSize
        )
        await details
    }

    private func activateEditorAfterTabUpdate(
        _ editorContext: WorkspaceQueryEditorContext
    ) {
        Task { @MainActor in
            await Task.yield()
            editorContext.commandCoordinator.activateEditor()
        }
    }

    private func makeTabItem(
        for document: WorkspaceQueryDocumentModel
    ) -> WorkspaceQueryTabItem {
        let documentID = document.id
        return WorkspaceQueryTabItem(
            document: document,
            editorContext: WorkspaceQueryEditorContext(
                document: document,
                schemaCatalog: model.schemaCatalog,
                prepareCompletionColumns: model.prepareCompletionColumns,
                save: { [weak self] in
                    self?.requestSaveQueryDocument(documentID)
                }
            )
        )
    }

    private func configureElasticsearchRequestDocument(
        _ document: WorkspaceElasticsearchRequestDocumentModel
    ) {
        document.configureSaveAction { [weak self, weak document] in
            guard let document else { return }
            self?.controller?.requestSaveElasticsearchRequestDocument(document)
        }
    }
}

private extension WorkspaceContentTabID {
    var databaseObjectSelection: WorkspaceDatabaseObjectSelection? {
        guard case let .databaseObject(selection) = self else { return nil }
        return selection
    }
}
