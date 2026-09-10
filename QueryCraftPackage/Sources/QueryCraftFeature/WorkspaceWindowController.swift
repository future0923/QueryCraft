import AppKit
import SwiftUI

@MainActor
final class WorkspaceWindowController: NSWindowController,
    NSWindowDelegate
{
    private static let frameAutosaveName = "QueryCraftWorkspaceWindow"
    private static let minimumWindowSize = NSSize(width: 1_000, height: 520)

    private weak var workspaceGroup: WorkspaceWindowGroup?
    private var model: WorkspaceModel
    private var tabsModel: WorkspaceContentTabsModel
    private let workspaceManager: WorkspaceWindowManager
    private(set) var presentation: WorkspaceWindowPresentation
    private var hostingController: NSHostingController<WorkspaceView>?
    private(set) var rootViewInstallationCount = 0
    private(set) var toolbarModel: WorkspaceToolbarModel
    private(set) var workspaceToolbar: WorkspaceWindowToolbar
    private var isClosing = false
    private var workspaceCloseTask: Task<Bool, Never>?

    init(
        workspaceGroup: WorkspaceWindowGroup,
        model: WorkspaceModel,
        tabsModel: WorkspaceContentTabsModel,
        initialFrame: NSRect? = nil,
        workspaceManager: WorkspaceWindowManager = .shared
    ) {
        self.workspaceGroup = workspaceGroup
        self.model = model
        self.tabsModel = tabsModel
        self.workspaceManager = workspaceManager
        let activeContext = workspaceGroup.activeDatabaseContext
        let presentation = WorkspaceWindowPresentation(
            context: activeContext,
            retainedContexts: workspaceGroup.databaseContexts,
            databaseContexts: workspaceGroup.databaseContextDescriptors,
            selectedDatabaseContextID: workspaceGroup.selectedContextID
        )
        self.presentation = presentation
        let toolbarModel = WorkspaceToolbarModel(
            presentation: presentation,
            createQueryDocument: { [weak workspaceGroup] in
                workspaceGroup?.createQueryDocument()
            },
            refreshWorkspace: { [weak workspaceGroup] in
                workspaceGroup?.refreshWorkspace()
            }
        )
        self.toolbarModel = toolbarModel
        workspaceToolbar = WorkspaceWindowToolbar(model: toolbarModel)

        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("workspace")
        window.minSize = Self.minimumWindowSize
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .automatic
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.animationBehavior = .none
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = model.profileName
        window.toolbar = workspaceToolbar.managedToolbar

        super.init(window: window)

        updateContent()

        if let initialFrame {
            window.setFrame(
                Self.frameFittingMinimumSize(initialFrame),
                display: false
            )
        } else if !window.setFrameUsingName(Self.frameAutosaveName) {
            let visibleSize = (window.screen ?? NSScreen.main)?.visibleFrame.size
                ?? NSSize(width: 1_440, height: 900)
            window.setContentSize(
                NSSize(
                    width: min(1_200, visibleSize.width),
                    height: min(800, visibleSize.height)
                )
            )
            window.center()
        }
        window.delegate = self
    }

    private static func frameFittingMinimumSize(_ frame: NSRect) -> NSRect {
        var result = frame
        result.size.width = max(result.width, minimumWindowSize.width)
        result.size.height = max(result.height, minimumWindowSize.height)
        return result
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceWindowController does not support NSCoder")
    }

    func requestExplicitClose(_ sender: Any? = nil) async -> Bool {
        guard let task = startWorkspaceClose(sender) else {
            return false
        }
        return await task.value
    }

    func requestCloseSelectedContent() {
        if let selectedContentID = tabsModel.selectedContentID {
            requestContentTabAction(.close(selectedContentID))
        } else {
            Task { @MainActor [weak self] in
                _ = await self?.requestExplicitClose()
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        workspaceGroup?.windowControllerDidBecomeKey(self)
        Task { @MainActor [weak self] in
            await self?.workspaceGroup?.refreshActiveSavedQueries()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        _ = startWorkspaceClose(sender)
        return false
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, !window.inLiveResize else { return }
        window.saveFrame(usingName: Self.frameAutosaveName)
        workspaceGroup?.windowFrameDidChange(window.frame, immediately: false)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        window.saveFrame(usingName: Self.frameAutosaveName)
        workspaceGroup?.windowFrameDidChange(window.frame, immediately: true)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        window.saveFrame(usingName: Self.frameAutosaveName)
        workspaceGroup?.windowFrameDidChange(window.frame, immediately: false)
    }

    func windowWillClose(_ notification: Notification) {
        workspaceToolbar.invalidate()
        workspaceGroup?.windowControllerDidClose(self)
    }

    private func updateContent() {
        guard workspaceGroup?.activeDatabaseContext != nil else { return }
        let rootView = WorkspaceView(
            presentation: presentation,
            toolbarModel: toolbarModel,
            loadConnectionProfiles: { [weak self] in
                guard let self else { return [] }
                return try await self.workspaceManager.fetchConnectionProfiles()
            },
            openConnection: { [weak self] profileID in
                guard let self else { return false }
                return try await self.workspaceManager.openWorkspace(
                    profileID: profileID,
                    attachedTo: self.window
                )
            },
            openDatabase: { [weak self] databaseName in
                self?.workspaceGroup?.openDatabase(databaseName)
            },
            selectDatabaseContext: { [weak self] contextID in
                self?.workspaceGroup?.selectDatabaseContext(contextID)
            },
            closeDatabaseContext: { [weak self] contextID in
                self?.requestCloseDatabaseContext(contextID)
            },
            closeOtherDatabaseContexts: { [weak self] contextID in
                self?.requestCloseOtherDatabaseContexts(keeping: contextID)
            },
            moveDatabaseContextToNewWindow: { [weak self] contextID in
                self?.workspaceGroup?.requestMoveDatabaseContextToNewWindow(
                    contextID
                )
            },
            savedQueryActions: makeSavedQueryActions(),
            openDatabaseObject: { [weak self] selection in
                self?.workspaceGroup?.openDatabaseObject(selection)
            },
            openRedisKey: { [weak self] reference in
                self?.workspaceGroup?.openRedisKey(reference)
            },
            tableDidRename: { [weak self] oldSelection, newSelection in
                self?.workspaceGroup?.tableDidRename(
                    from: oldSelection,
                    to: newSelection
                )
            },
            tableDidDelete: { [weak self] selection in
                self?.workspaceGroup?.tableDidDelete(selection)
            },
            createTable: { [weak self] databaseName in
                self?.workspaceGroup?.createTableDraft(in: databaseName)
            },
            selectContent: { [weak self] contentID in
                self?.workspaceGroup?.selectContent(contentID)
            },
            performContentTabAction: { [weak self] action in
                self?.requestContentTabAction(action)
            },
            closeSelectedContent: { [weak self] in
                self?.requestCloseSelectedContent()
            },
            redisKeyDidDelete: { [weak self] reference in
                self?.requestContentTabAction(.close(.redisKey(reference)))
            },
            redisKeyDidRename: { [weak self] oldReference, newReference in
                self?.workspaceGroup?.redisKeyDidRename(
                    from: oldReference,
                    to: newReference
                )
            },
            retryConnection: { [weak self] in
                self?.workspaceGroup?.retryConnection()
            }
        )
        let hostingController = NSHostingController(rootView: rootView)
        self.hostingController = hostingController
        window?.contentViewController = hostingController
        rootViewInstallationCount += 1
    }

    private func requestCloseDatabaseContext(_ contextID: UUID) {
        guard !isClosing else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.closeDatabaseContext(contextID)
        }
    }

    private func requestCloseOtherDatabaseContexts(keeping contextID: UUID) {
        guard !isClosing else { return }
        Task { @MainActor [weak self] in
            guard let self, let workspaceGroup else { return }
            let contextIDs = workspaceGroup.databaseContexts
                .map(\.id)
                .filter { $0 != contextID }
            for contextID in contextIDs {
                guard await self.closeDatabaseContext(contextID) else { return }
            }
            workspaceGroup.selectDatabaseContext(contextID)
        }
    }

    private func requestContentTabAction(
        _ action: WorkspaceContentTabAction
    ) {
        guard !isClosing else { return }

        if case let .closeOthers(contentID) = action {
            workspaceGroup?.selectContent(contentID)
        }

        let contentIDsToClose = tabsModel.contentIDs(for: action)
        guard !contentIDsToClose.isEmpty else { return }
        isClosing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            for contentID in contentIDsToClose {
                guard await self.closeContentTab(contentID) else { break }
            }
            self.isClosing = false
        }
    }

    private func closeContentTab(
        _ contentID: WorkspaceContentTabID
    ) async -> Bool {
        guard let item = tabsModel.contentItems.first(where: {
            $0.id == contentID
        }) else {
            return true
        }

        if presentation.context.pendingChangesRegistry.actions(
            for: contentID
        )?.hasChanges == true {
            workspaceGroup?.selectContent(contentID)
            await presentPendingChangesCloseBlock()
            return false
        }

        switch item {
        case let .databaseObject(selection):
            workspaceGroup?.closeDatabaseObjectTab(selection)
            return true
        case .newTable, .redisKey, .redisCommand, .elasticsearchRequest:
            tabsModel.removeContent(contentID)
            workspaceGroup?.activateSelectedContentAfterClosingTab()
            return true
        case let .query(queryItem):
            queryItem.editorContext.commandCoordinator.synchronizeDocumentText()
            return await performQueryDocumentCloseFlow(queryItem.id)
        }
    }

    private func closeDatabaseContext(_ contextID: UUID) async -> Bool {
        guard let workspaceGroup,
              workspaceGroup.databaseContexts.count > 1
        else {
            return false
        }
        workspaceGroup.selectDatabaseContext(contextID)
        let queryItems = tabsModel.items
        for item in queryItems {
            item.editorContext.commandCoordinator.synchronizeDocumentText()
            guard await performQueryDocumentCloseFlow(item.id) else {
                return false
            }
        }
        await workspaceGroup.removeDatabaseContext(contextID)
        return true
    }

    func replaceWorkspace() {
        guard let workspaceGroup else { return }
        let context = workspaceGroup.activeDatabaseContext
        model = context.model
        tabsModel = context.tabsModel
        presentation.activate(
            context,
            retainedContexts: workspaceGroup.databaseContexts,
            databaseContexts: workspaceGroup.databaseContextDescriptors,
            selectedDatabaseContextID: workspaceGroup.selectedContextID
        )
        window?.title = context.model.profileName
    }

    func presentSavedQueryExternalChanges(
        _ changes: [WorkspaceSavedQueryExternalChange]
    ) async {
        for change in changes {
            guard let window, window.attachedSheet == nil else { return }
            switch change {
            case let .changed(document, query):
                guard document.hasUnresolvedExternalChange(from: query) else {
                    continue
                }
                let alert = NSAlert()
                alert.messageText = AppCopy.current.text(
                    "查询已更改",
                    "Query Changed"
                )
                alert.informativeText = AppCopy.current.text(
                    "“\(query.name)”已在其他位置更改。要重新载入吗？",
                    "\"\(query.name)\" changed elsewhere. Do you want to reload it?"
                )
                alert.alertStyle = .warning
                let reloadButton = alert.addButton(
                    withTitle: AppCopy.current.text("重新载入", "Reload")
                )
                let ignoreButton = alert.addButton(
                    withTitle: AppCopy.current.text("忽略", "Ignore")
                )
                reloadButton.keyEquivalent = "\r"
                ignoreButton.keyEquivalent = "\u{1b}"
                alert.window.initialFirstResponder = reloadButton
                let response = await sheetResponse(for: alert, window: window)
                if response == .alertFirstButtonReturn {
                    await model.reloadQueryDocument(document, from: query)
                } else {
                    await model.ignoreQueryDocumentExternalChange(
                        document,
                        from: query
                    )
                }

            case let .deleted(document):
                guard document.savedQueryID != nil else { continue }
                let alert = NSAlert()
                alert.messageText = AppCopy.current.text(
                    "查询已被删除",
                    "Query Deleted"
                )
                alert.informativeText = AppCopy.current.text(
                    "“\(document.title)”已在其他位置删除。要重新保存吗？",
                    "\"\(document.title)\" was deleted elsewhere. Do you want to save it again?"
                )
                alert.alertStyle = .warning
                let resaveButton = alert.addButton(
                    withTitle: AppCopy.current.text("重新保存", "Resave")
                )
                let ignoreButton = alert.addButton(
                    withTitle: AppCopy.current.text("忽略", "Ignore")
                )
                resaveButton.keyEquivalent = "\r"
                ignoreButton.keyEquivalent = "\u{1b}"
                alert.window.initialFirstResponder = resaveButton
                let response = await sheetResponse(for: alert, window: window)
                if response == .alertFirstButtonReturn {
                    let name = document.title
                    model.detachDeletedQueryDocument(document)
                    do {
                        try await workspaceGroup?.saveQueryDocument(
                            document.id,
                            name: name
                        )
                    } catch {
                        presentSaveFailure(error.localizedDescription)
                    }
                } else {
                    model.detachDeletedQueryDocument(document)
                }
            }
        }
    }

    private func sheetResponse(
        for alert: NSAlert,
        window: NSWindow
    ) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private func makeSavedQueryActions() -> WorkspaceSavedQueryActions {
        WorkspaceSavedQueryActions(
            open: { [weak self] savedQueryID in
                self?.workspaceGroup?.openSavedQuery(savedQueryID)
            },
            rename: { [weak self] savedQueryID in
                self?.requestRenameSavedQuery(savedQueryID)
            },
            duplicate: { [weak self] savedQueryID in
                self?.requestDuplicateSavedQuery(savedQueryID)
            },
            move: { [weak self] savedQueryID, databaseName in
                self?.requestMoveSavedQuery(
                    savedQueryID,
                    to: databaseName
                )
            },
            delete: { [weak self] savedQueryID in
                self?.requestDeleteSavedQuery(savedQueryID)
            }
        )
    }

    private func requestRenameSavedQuery(_ savedQueryID: SavedQuery.ID) {
        guard !isClosing else { return }
        Task { @MainActor [weak self] in
            await self?.renameSavedQuery(savedQueryID)
        }
    }

    private func requestDuplicateSavedQuery(_ savedQueryID: SavedQuery.ID) {
        guard !isClosing else { return }
        Task { @MainActor [weak self] in
            await self?.performSavedQueryOperation {
                _ = try await self?.workspaceGroup?.duplicateSavedQuery(
                    savedQueryID
                )
            }
        }
    }

    private func requestMoveSavedQuery(
        _ savedQueryID: SavedQuery.ID,
        to databaseName: String?
    ) {
        guard !isClosing else { return }
        Task { @MainActor [weak self] in
            await self?.performSavedQueryOperation {
                _ = try await self?.model.moveSavedQuery(
                    savedQueryID,
                    to: databaseName
                )
            }
        }
    }

    private func requestDeleteSavedQuery(_ savedQueryID: SavedQuery.ID) {
        guard !isClosing else { return }
        Task { @MainActor [weak self] in
            await self?.deleteSavedQuery(savedQueryID)
        }
    }

    private func renameSavedQuery(_ savedQueryID: SavedQuery.ID) async {
        guard let query = model.savedQuery(id: savedQueryID),
              let window,
              window.attachedSheet == nil
        else {
            NSSound.beep()
            return
        }

        let nameField = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 320, height: 24)
        )
        nameField.stringValue = query.name
        nameField.placeholderString = AppCopy.current.text("查询名称", "Query Name")
        nameField.selectText(nil)

        let alert = NSAlert()
        alert.messageText = AppCopy.current.text(
            "重命名已保存查询",
            "Rename Saved Query"
        )
        alert.informativeText =
            AppCopy.current.text(
                "请输入这个已保存查询的新名称。",
                "Enter a new name for this Saved Query."
            )
        alert.alertStyle = .informational
        alert.accessoryView = nameField
        alert.addButton(withTitle: AppCopy.current.text("重命名", "Rename"))
        alert.addButton(withTitle: AppCopy.current.text("取消", "Cancel"))
        alert.window.initialFirstResponder = nameField

        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
        guard response == .alertFirstButtonReturn else { return }
        await performSavedQueryOperation {
            _ = try await workspaceGroup?.renameSavedQuery(
                savedQueryID,
                name: nameField.stringValue
            )
        }
    }

    private func deleteSavedQuery(_ savedQueryID: SavedQuery.ID) async {
        guard let query = model.savedQuery(id: savedQueryID),
              let window,
              window.attachedSheet == nil
        else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = AppCopy.current.text(
            "删除“\(query.name)”？",
            "Delete \"\(query.name)\"?"
        )
        alert.informativeText =
            AppCopy.current.text(
                "这会删除已保存查询并关闭当前位置中打开的标签。其他位置会在激活时提示是否重新保存。",
                "This removes the Saved Query and closes its tab here. Other open copies will ask whether to save it again when activated."
            )
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(
            withTitle: AppCopy.current.text("删除", "Delete")
        )
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: AppCopy.current.text("取消", "Cancel"))

        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
        guard response == .alertFirstButtonReturn else { return }
        do {
            let documentIDs = try await workspaceGroup?.deleteSavedQuery(
                savedQueryID
            ) ?? []
            for documentID in documentIDs {
                guard let document = model.queryDocuments.first(where: {
                    $0.id == documentID
                }) else {
                    continue
                }
                _ = workspaceGroup?.closeQueryDocumentInBackground(
                    documentID,
                    authorization: .discardingCurrentChanges(in: document)
                )
            }
        } catch {
            presentSavedQueryFailure(error.localizedDescription)
        }
    }

    private func performSavedQueryOperation(
        _ operation: @MainActor () async throws -> Void
    ) async {
        do {
            try await operation()
        } catch {
            presentSavedQueryFailure(error.localizedDescription)
        }
    }

    private func presentSavedQueryFailure(_ message: String) {
        guard let window, window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = AppCopy.current.text(
            "无法更改已保存查询",
            "Unable to Change Saved Query"
        )
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: AppCopy.current.text("好", "OK"))
        alert.beginSheetModal(for: window)
    }

    func requestSaveQueryDocument(_ documentID: UUID) {
        guard !isClosing,
              let document = model.queryDocuments.first(where: {
                  $0.id == documentID
              }),
              document.canSave
        else {
            return
        }

        Task { @MainActor [weak self] in
            _ = await self?.saveQueryDocument(documentID)
        }
    }

    func requestSaveElasticsearchRequestDocument(
        _ document: WorkspaceElasticsearchRequestDocumentModel
    ) {
        guard !isClosing, document.canSave else { return }
        Task { @MainActor [weak self, weak document] in
            guard let self, let document, let workspaceGroup else { return }
            let name: String?
            if document.savedQueryID == nil {
                guard let requestedName = await requestSaveName(
                    defaultName: document.title
                ) else { return }
                name = requestedName
            } else {
                name = nil
            }
            do {
                try await workspaceGroup.saveElasticsearchRequestDocument(
                    document,
                    name: name
                )
            } catch {
                presentSaveFailure(error.localizedDescription)
            }
        }
    }

    private func requestSaveName(
        for document: WorkspaceQueryDocumentModel
    ) async -> String? {
        await requestSaveName(defaultName: document.title)
    }

    private func requestSaveName(
        defaultName: String
    ) async -> String? {
        guard let window, window.attachedSheet == nil else {
            NSSound.beep()
            return nil
        }

        let nameField = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 320, height: 24)
        )
        nameField.stringValue = defaultName
        nameField.placeholderString = AppCopy.current.text("查询名称", "Query Name")
        nameField.selectText(nil)

        let alert = NSAlert()
        alert.messageText = AppCopy.current.text("保存查询", "Save Query")
        alert.informativeText =
            AppCopy.current.text(
                "请为当前连接配置中的查询选择名称。",
                "Choose a name for this query in the current connection."
            )
        alert.alertStyle = .informational
        alert.accessoryView = nameField
        alert.addButton(withTitle: AppCopy.current.text("保存", "Save"))
        alert.addButton(withTitle: AppCopy.current.text("取消", "Cancel"))
        alert.window.initialFirstResponder = nameField

        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
        guard response == .alertFirstButtonReturn else { return nil }
        return nameField.stringValue
    }

    private func saveQueryDocument(
        _ documentID: UUID
    ) async -> Bool {
        guard let workspaceGroup,
              let document = model.queryDocuments.first(where: {
                  $0.id == documentID
              })
        else {
            return false
        }

        let name: String?
        if document.savedQueryID == nil {
            guard let requestedName = await requestSaveName(for: document)
            else {
                return false
            }
            name = requestedName
        } else {
            name = nil
        }

        do {
            try await workspaceGroup.saveQueryDocument(
                documentID,
                name: name
            )
            return true
        } catch {
            presentSaveFailure(error.localizedDescription)
            return false
        }
    }

    private func presentSaveFailure(_ message: String) {
        guard let window, window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = AppCopy.current.text("无法保存查询", "Unable to Save Query")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: AppCopy.current.text("好", "OK"))
        alert.beginSheetModal(for: window)
    }

    private func requestUnsavedChangesDecision(
        for document: WorkspaceQueryDocumentModel
    ) async -> UnsavedChangesDecision {
        guard let window, window.attachedSheet == nil else {
            NSSound.beep()
            return .cancel
        }

        let alert = NSAlert()
        alert.messageText =
            AppCopy.current.text(
                "要保存对“\(document.title)”的更改吗？",
                "Do you want to save changes to \"\(document.title)\"?"
            )
        alert.informativeText =
            AppCopy.current.text(
                "如果不保存，更改将会丢失。",
                "Your changes will be lost if you don't save them."
            )
        alert.alertStyle = .warning
        alert.addButton(withTitle: AppCopy.current.text("保存", "Save"))
        alert.addButton(withTitle: AppCopy.current.text("取消", "Cancel"))
        let dontSaveButton = alert.addButton(
            withTitle: AppCopy.current.text("不保存", "Don't Save")
        )
        dontSaveButton.keyEquivalent = "d"
        dontSaveButton.keyEquivalentModifierMask = .command

        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
        switch response {
        case .alertFirstButtonReturn:
            return .save
        case .alertThirdButtonReturn:
            return .dontSave
        default:
            return .cancel
        }
    }

    private func confirmTransactionRollbackBeforeClose() async -> Bool {
        guard let window, window.attachedSheet == nil else {
            NSSound.beep()
            return false
        }
        let alert = NSAlert()
        alert.messageText = AppCopy.current.text(
            "回滚事务并关闭？",
            "Roll Back Transaction and Close?"
        )
        alert.informativeText =
            AppCopy.current.text(
                "此查询文档有一个活动事务。关闭标签页前将回滚所有未提交的更改。",
                "This Query Document has an active transaction. Its uncommitted changes will be rolled back before the tab closes."
            )
        alert.alertStyle = .warning
        alert.addButton(
            withTitle: AppCopy.current.text("回滚并关闭", "Roll Back and Close")
        )
        alert.addButton(withTitle: AppCopy.current.text("取消", "Cancel"))

        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
        return response == .alertFirstButtonReturn
    }

    private func startWorkspaceClose(
        _ sender: Any?
    ) -> Task<Bool, Never>? {
        if let workspaceCloseTask {
            return workspaceCloseTask
        }
        guard !isClosing else { return nil }
        isClosing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            let contextIDs = self.workspaceGroup?.databaseContexts.map(\.id)
                ?? []
            for contextID in contextIDs {
                self.workspaceGroup?.selectDatabaseContext(contextID)
                if let pendingContentID = self.tabsModel.contentItems
                    .map(\.id)
                    .first(where: {
                        self.presentation.context.pendingChangesRegistry
                            .actions(for: $0)?.hasChanges == true
                    })
                {
                    self.workspaceGroup?.selectContent(pendingContentID)
                    await self.presentPendingChangesCloseBlock()
                    self.isClosing = false
                    self.workspaceCloseTask = nil
                    return false
                }
                let queryItems = self.tabsModel.items
                for item in queryItems {
                    item.editorContext.commandCoordinator
                        .synchronizeDocumentText()
                    guard await self.performQueryDocumentCloseFlow(item.id)
                    else {
                        self.isClosing = false
                        self.workspaceCloseTask = nil
                        return false
                    }
                }
            }
            await self.workspaceGroup?.prepareForExplicitClose()
            self.closeWindow(sender)
            self.workspaceCloseTask = nil
            return true
        }
        workspaceCloseTask = task
        return task
    }

    private func presentPendingChangesCloseBlock() async {
        guard let window, window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = AppCopy.current.text(
            "先处理待提交更改",
            "Resolve Pending Changes"
        )
        alert.informativeText = AppCopy.current.text(
            "请先通过工具栏提交或放弃当前更改，然后再关闭。",
            "Commit or discard the current changes from the toolbar before closing."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: AppCopy.current.text("继续编辑", "Continue Editing"))
        _ = await sheetResponse(for: alert, window: window)
    }

    private func performQueryDocumentCloseFlow(
        _ documentID: UUID
    ) async -> Bool {
        while true {
            guard let workspaceGroup,
                  let document = model.queryDocuments.first(where: {
                      $0.id == documentID
                  })
            else {
                return true
            }

            if let message = document.preflightCloseFailureMessage {
                presentCloseFailure(message)
                return false
            }

            let authorization: WorkspaceQueryDocumentCloseAuthorization
            if document.isDirty {
                switch await requestUnsavedChangesDecision(for: document) {
                case .save:
                    guard await saveQueryDocument(documentID) else {
                        return false
                    }
                    continue
                case .dontSave:
                    authorization = .discardingCurrentChanges(in: document)
                case .cancel:
                    return false
                }
            } else {
                authorization = .preservingChanges
            }

            let result: WorkspaceQueryDocumentCloseResult
            if document.transactionState == .inTransaction {
                guard await confirmTransactionRollbackBeforeClose() else {
                    return false
                }
                result = await workspaceGroup.closeQueryDocumentAfterRollback(
                    documentID,
                    authorization: authorization
                )
            } else {
                result = workspaceGroup.closeQueryDocumentInBackground(
                    documentID,
                    authorization: authorization
                )
            }

            if result == .needsUnsavedChangesDecision {
                continue
            }
            switch result {
            case .closed:
                return true
            case .needsUnsavedChangesDecision:
                continue
            case let .failed(message):
                presentCloseFailure(message)
                return false
            }
        }
    }

    private func presentCloseFailure(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = AppCopy.current.text("无法关闭查询", "Unable to Close Query")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: AppCopy.current.text("好", "OK"))
        alert.beginSheetModal(for: window)
    }

    private func closeWindow(_ sender: Any?) {
        isClosing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            (window as? WorkspaceWindow)?.closeAfterApproval()
        }
    }
}

private enum UnsavedChangesDecision {
    case save
    case dontSave
    case cancel
}
