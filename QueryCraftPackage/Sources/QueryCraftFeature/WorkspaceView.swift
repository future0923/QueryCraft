import AppKit
import SwiftUI

public struct WorkspaceView: View {
    private static let sidebarMinimumWidth =
        WorkspaceSidebarLayout.minimumWidth
    private static let detailMinimumWidth: CGFloat = 520

    @Bindable private var presentation: WorkspaceWindowPresentation
    @Bindable private var toolbarModel: WorkspaceToolbarModel
    private let loadConnectionProfiles:
        WorkspaceConnectionPickerModel.ProfileLoader
    private let openConnection:
        @MainActor (ConnectionProfile.ID) async throws -> Bool
    private let openDatabase: @MainActor (String) -> Void
    private let selectDatabaseContext: @MainActor (UUID) -> Void
    private let closeDatabaseContext: @MainActor (UUID) -> Void
    private let closeOtherDatabaseContexts: @MainActor (UUID) -> Void
    private let moveDatabaseContextToNewWindow: @MainActor (UUID) -> Void
    @State private var preferences = ApplicationPreferences.shared
    private let savedQueryActions: WorkspaceSavedQueryActions
    private let openDatabaseObject: @MainActor (
        WorkspaceDatabaseObjectSelection
    ) -> Void
    private let openRedisKey: @MainActor (RedisKeyReference) -> Void
    private let tableDidRename: @MainActor (
        WorkspaceDatabaseObjectSelection,
        WorkspaceDatabaseObjectSelection
    ) -> Void
    private let tableDidDelete: @MainActor (
        WorkspaceDatabaseObjectSelection
    ) -> Void
    private let createTable: @MainActor (String) -> Void
    private let selectContent: @MainActor (WorkspaceContentTabID) -> Void
    private let performContentTabAction: @MainActor (
        WorkspaceContentTabAction
    ) -> Void
    private let closeSelectedContent: @MainActor () -> Void
    private let redisKeyDidDelete: @MainActor (RedisKeyReference) -> Void
    private let redisKeyDidRename: @MainActor (
        RedisKeyReference,
        RedisKeyReference
    ) -> Void
    private let retryConnection: @MainActor () -> Void
    @State private var connectionPickerModel:
        WorkspaceConnectionPickerModel?
    @State private var showsDatabasePicker = false
    @State private var showsSidebar = true
    @State private var driverInstallationProfile: ConnectionProfile?
    @State private var connectionOpenErrorMessage = ""
    @State private var isShowingConnectionOpenError = false
    @State private var connectionPickerLoadTask: Task<Void, Never>?
    @State private var connectionOpenTask: Task<Void, Never>?

    public var body: some View {
        @Bindable var model = presentation.context.model
        @Bindable var tabsModel = presentation.context.tabsModel

        GeometryReader { geometry in
            WorkspaceMainSplitView(
                showsSidebar: showsSidebar,
                showsInspector: toolbarModel.showsInspector,
                sidebarMinimumWidth: combinedSidebarMinimumWidth,
                sidebarMaximumWidth: 600,
                detailMinimumWidth: Self.detailMinimumWidth,
                inspectorMinimumWidth: 240
            ) {
                HStack(spacing: 0) {
                    if databaseContexts.count > 1 {
                        WorkspaceDatabaseRail(
                            contexts: databaseContexts,
                            selectedContextID: selectedDatabaseContextID,
                            selectContext: selectDatabaseContext,
                            closeContext: closeDatabaseContext,
                            closeOtherContexts: closeOtherDatabaseContexts,
                            moveContextToNewWindow:
                                moveDatabaseContextToNewWindow
                        )
                    }

                    WorkspaceSidebar(
                        model: model,
                        savedQueryActions: savedQueryActions,
                        openDatabaseObject: openDatabaseObject,
                        openRedisKey: openRedisKey,
                        renameRedisKey: { reference in
                            openRedisKey(reference)
                            redisKeyActionRegistry.requestRename(for: reference)
                        },
                        openDatabaseObjectTab: { selection, tab in
                            openDatabaseObject(selection)
                            objectDetailTabRegistry.request(
                                tab,
                                for: selection
                            )
                        },
                        tableDidRename: tableDidRename,
                        tableDidDelete: tableDidDelete,
                        createTable: createTable,
                        showDatabasePicker: { showsDatabasePicker = true }
                    )
                    .frame(
                        minWidth: Self.sidebarMinimumWidth,
                        maxWidth: .infinity
                    )
                }
            } detail: {
                WorkspaceDetailView(
                    model: model,
                    tabsModel: tabsModel,
                    contentRefreshRegistry: contentRefreshRegistry,
                    pendingChangesRegistry: pendingChangesRegistry,
                    inspectorRegistry: inspectorRegistry,
                    objectDetailTabRegistry: objectDetailTabRegistry,
                    redisKeyActionRegistry: redisKeyActionRegistry,
                    hostController: contentHostController,
                    retainedHostControllers: presentation.retainedContexts.map(
                        \.contentHostController
                    ),
                    selectContent: selectContent,
                    performContentTabAction: performContentTabAction,
                    retryConnection: retryConnection
                )
                .frame(minWidth: Self.detailMinimumWidth)
            } inspector: {
                WorkspaceInspectorView(
                    context: selectedInspectorContext
                )
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height + geometry.safeAreaInsets.top
            )
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 1_000, minHeight: 520)
        .sheet(item: $connectionPickerModel) { pickerModel in
            WorkspaceConnectionPicker(
                model: pickerModel,
                selectConnection: requestConnectionOpen,
                dismiss: { connectionPickerModel = nil }
            )
        }
        .sheet(isPresented: $showsDatabasePicker) {
            WorkspaceDatabasePicker(
                databaseNames: model.availableDatabaseNames,
                databaseKeyCounts: model.availableDatabaseKeyCounts,
                selectedDatabaseName: model.databaseContextName,
                selectDatabase: openDatabase,
                dismiss: { showsDatabasePicker = false }
            )
        }
        .sheet(item: $driverInstallationProfile) { profile in
            ConnectionProfileDriverInstallationSheet(
                profile: profile,
                openProfile: { startOpeningConnection(profile) }
            )
        }
        .environment(\.locale, preferences.interfaceLocale)
        .focusedSceneValue(
            \.workspaceDatabaseActions,
            WorkspaceDatabaseCommandActions(
                openConnectionPicker: prepareConnectionPicker,
                canOpenDatabasePicker: model.databaseType != .elasticsearch,
                openDatabasePicker: {
                    guard model.databaseType != .elasticsearch else { return }
                    showsDatabasePicker = true
                },
                refreshWorkspace: toolbarModel.refreshWorkspace
            )
        )
        .focusedSceneValue(
            \.workspacePendingChangesActions,
            toolbarModel.focusedPendingChangesActions
        )
        .focusedSceneValue(
            \.workspaceContentTabActions,
            workspaceContentTabActions
        )
        .background {
            Group {
                WorkspacePendingChangesKeyCommandHandler(
                    actions: toolbarModel.focusedPendingChangesActions
                )
                WorkspaceContentTabKeyCommandHandler(
                    actions: workspaceContentTabActions
                )
                WorkspaceSidebarKeyCommandHandler(
                    toggleSidebar: { showsSidebar.toggle() },
                    openConnectionPicker: prepareConnectionPicker
                )
            }
        }
        .accessibilityIdentifier("workspaceView")
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.invalidateCompletionColumns()
        }
        .onDisappear {
            connectionPickerLoadTask?.cancel()
            connectionPickerLoadTask = nil
            connectionOpenTask?.cancel()
            connectionOpenTask = nil
        }
        .onChange(of: presentation.sidebarToggleRequestID) {
            showsSidebar.toggle()
        }
        .onChange(of: presentation.connectionPickerRequestID) {
            prepareConnectionPicker()
        }
        .onChange(of: presentation.databasePickerRequestID) {
            guard model.databaseType != .elasticsearch else { return }
            showsDatabasePicker = true
        }
        .onChange(of: model.redisKeyDeletionRevision) {
            guard let reference = model.lastDeletedRedisKey else { return }
            redisKeyDidDelete(reference)
        }
        .onChange(of: model.redisKeyRenameRevision) {
            guard let renamed = model.lastRenamedRedisKey else { return }
            redisKeyDidRename(renamed.old, renamed.new)
        }
        .onChange(of: showsSidebar, initial: true) { _, isVisible in
            presentation.setSidebarVisible(isVisible)
        }
        .alert(
            AppCopy.current.text(
                "无法打开连接",
                "Unable to Open Connection"
            ),
            isPresented: $isShowingConnectionOpenError
        ) { } message: {
            Text(connectionOpenErrorMessage)
        }
        .alert(
            AppCopy.current.text(
                "无法保留可恢复草稿",
                "Unable to Preserve Recoverable Draft"
            ),
            isPresented: $model.isShowingRecoverableDraftError
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(model.recoverableDraftErrorMessage)
        }
        .alert(
            AppCopy.current.text(
                "无法保留工作区",
                "Unable to Preserve Workspace"
            ),
            isPresented: $model.isShowingWorkspaceRestorationError
        ) { } message: {
            Text(model.workspaceRestorationErrorMessage)
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $toolbarModel.showsDisableSafetyLockConfirmation
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive,
                action: toolbarModel.disableSafetyLock
            )
            .keyboardShortcut(.defaultAction)
            Button(
                AppCopy.current.text("取消", "Cancel"),
                role: .cancel
            ) {}
            .keyboardShortcut(.cancelAction)
        } message: {
            Text(
                AppCopy.current.text(
                    "在此工作区关闭前，可执行更改数据或数据库结构的语句。只读查询不受影响。",
                    "Statements that change data or database structure can run until this workspace closes. Read-only queries are unaffected."
                )
            )
        }
    }

    init(
        presentation: WorkspaceWindowPresentation,
        toolbarModel: WorkspaceToolbarModel,
        loadConnectionProfiles: @escaping
            WorkspaceConnectionPickerModel.ProfileLoader = { [] },
        openConnection: @escaping @MainActor (
            ConnectionProfile.ID
        ) async throws -> Bool = { _ in false },
        openDatabase: @escaping @MainActor (String) -> Void = { _ in },
        selectDatabaseContext: @escaping @MainActor (UUID) -> Void = { _ in },
        closeDatabaseContext: @escaping @MainActor (UUID) -> Void = { _ in },
        closeOtherDatabaseContexts: @escaping @MainActor (UUID) -> Void = { _ in },
        moveDatabaseContextToNewWindow: @escaping @MainActor (UUID) -> Void = { _ in },
        savedQueryActions: WorkspaceSavedQueryActions,
        openDatabaseObject: @escaping @MainActor (
            WorkspaceDatabaseObjectSelection
        ) -> Void,
        openRedisKey: @escaping @MainActor (RedisKeyReference) -> Void = { _ in },
        tableDidRename: @escaping @MainActor (
            WorkspaceDatabaseObjectSelection,
            WorkspaceDatabaseObjectSelection
        ) -> Void = { _, _ in },
        tableDidDelete: @escaping @MainActor (
            WorkspaceDatabaseObjectSelection
        ) -> Void = { _ in },
        createTable: @escaping @MainActor (String) -> Void = { _ in },
        selectContent: @escaping @MainActor (
            WorkspaceContentTabID
        ) -> Void,
        performContentTabAction: @escaping @MainActor (
            WorkspaceContentTabAction
        ) -> Void = { _ in },
        closeSelectedContent: @escaping @MainActor () -> Void,
        redisKeyDidDelete: @escaping @MainActor (
            RedisKeyReference
        ) -> Void = { _ in },
        redisKeyDidRename: @escaping @MainActor (
            RedisKeyReference,
            RedisKeyReference
        ) -> Void = { _, _ in },
        retryConnection: @escaping @MainActor () -> Void
    ) {
        self.presentation = presentation
        self.toolbarModel = toolbarModel
        self.loadConnectionProfiles = loadConnectionProfiles
        self.openConnection = openConnection
        self.openDatabase = openDatabase
        self.selectDatabaseContext = selectDatabaseContext
        self.closeDatabaseContext = closeDatabaseContext
        self.closeOtherDatabaseContexts = closeOtherDatabaseContexts
        self.moveDatabaseContextToNewWindow = moveDatabaseContextToNewWindow
        self.savedQueryActions = savedQueryActions
        self.openDatabaseObject = openDatabaseObject
        self.openRedisKey = openRedisKey
        self.tableDidRename = tableDidRename
        self.tableDidDelete = tableDidDelete
        self.createTable = createTable
        self.selectContent = selectContent
        self.performContentTabAction = performContentTabAction
        self.closeSelectedContent = closeSelectedContent
        self.redisKeyDidDelete = redisKeyDidDelete
        self.redisKeyDidRename = redisKeyDidRename
        self.retryConnection = retryConnection
    }

    private func requestConnectionOpen(_ profile: ConnectionProfile) {
        guard profile.id != model.profileID else { return }
        guard connectionOpenTask == nil else { return }

        connectionOpenTask = Task { @MainActor in
            defer { connectionOpenTask = nil }
            await Task.yield()
            guard !Task.isCancelled else { return }

            if await DatabaseDriverManager.shared.isInstalled(
                profile.databaseType
            ) {
                await openConnectionProfile(profile)
            } else {
                driverInstallationProfile = profile
            }
        }
    }

    private func prepareConnectionPicker() {
        guard connectionPickerModel == nil else { return }
        guard connectionPickerLoadTask == nil else { return }

        let pickerModel = WorkspaceConnectionPickerModel(
            currentProfileID: model.profileID,
            loadProfiles: loadConnectionProfiles
        )
        connectionPickerLoadTask = Task { @MainActor in
            defer { connectionPickerLoadTask = nil }
            await pickerModel.load()
            guard !Task.isCancelled else { return }
            connectionPickerModel = pickerModel
        }
    }

    private func startOpeningConnection(_ profile: ConnectionProfile) {
        guard connectionOpenTask == nil else { return }
        connectionOpenTask = Task { @MainActor in
            defer { connectionOpenTask = nil }
            await Task.yield()
            guard !Task.isCancelled else { return }
            await openConnectionProfile(profile)
        }
    }

    private func openConnectionProfile(_ profile: ConnectionProfile) async {
        do {
            _ = try await openConnection(profile.id)
        } catch is CancellationError {
            return
        } catch {
            connectionOpenErrorMessage = error.localizedDescription
            isShowingConnectionOpenError = true
        }
    }

    private var model: WorkspaceModel { presentation.context.model }

    private var tabsModel: WorkspaceContentTabsModel {
        presentation.context.tabsModel
    }

    private var databaseContexts: [WorkspaceDatabaseContextDescriptor] {
        presentation.databaseContexts
    }

    private var selectedDatabaseContextID: UUID {
        presentation.selectedDatabaseContextID
    }

    private var contentHostController: WorkspaceRetainedContentHostController {
        presentation.context.contentHostController
    }

    private var contentRefreshRegistry: WorkspaceContentRefreshRegistry {
        presentation.context.contentRefreshRegistry
    }

    private var pendingChangesRegistry: WorkspacePendingChangesRegistry {
        presentation.context.pendingChangesRegistry
    }

    private var inspectorRegistry: WorkspaceInspectorRegistry {
        presentation.context.inspectorRegistry
    }

    private var objectDetailTabRegistry:
        WorkspaceDatabaseObjectDetailTabRegistry
    {
        presentation.context.objectDetailTabRegistry
    }

    private var redisKeyActionRegistry: WorkspaceRedisKeyActionRegistry {
        presentation.context.redisKeyActionRegistry
    }

    private var workspaceContentTabActions: WorkspaceContentTabCommandActions {
        WorkspaceContentTabCommandActions(
            canCreateQuery: model.connectionState == .connected,
            hasContentTabs: !tabsModel.contentItems.isEmpty,
            createDocumentTitle: model.databaseType == .redis
                ? AppCopy.current.text(
                    "新建 Command 标签页",
                    "New Command Tab"
                )
                : AppCopy.current.text("新建查询标签页", "New Query Tab"),
            createQuery: toolbarModel.createQueryDocument,
            closeSelected: closeSelectedContent,
            selectAtIndex: { index in
                tabsModel.select(at: index)
                if let selectedContentID = tabsModel.selectedContentID {
                    selectContent(selectedContentID)
                }
            },
            selectRelative: { offset in
                tabsModel.select(offsetBy: offset)
                if let selectedContentID = tabsModel.selectedContentID {
                    selectContent(selectedContentID)
                }
            }
        )
    }

    private var selectedInspectorContext: WorkspaceInspectorContext? {
        inspectorRegistry.context(
            for: tabsModel.selectedContentID
        )
    }

    private var databaseRailWidth: CGFloat {
        databaseContexts.count > 1 ? WorkspaceDatabaseRail.width : 0
    }

    private var combinedSidebarMinimumWidth: CGFloat {
        Self.sidebarMinimumWidth + databaseRailWidth
    }
}
