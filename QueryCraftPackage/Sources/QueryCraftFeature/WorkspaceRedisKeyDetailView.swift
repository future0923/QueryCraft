import AppKit
import SwiftUI

struct WorkspaceRedisKeyDetailView: View {
    let reference: RedisKeyReference
    @Bindable var model: WorkspaceModel
    let contentRefreshRegistry: WorkspaceContentRefreshRegistry
    let pendingChangesRegistry: WorkspacePendingChangesRegistry
    let inspectorRegistry: WorkspaceInspectorRegistry
    let redisKeyActionRegistry: WorkspaceRedisKeyActionRegistry

    @State private var details: RedisKeyDetails?
    @State private var editor = RedisKeyEditorState()
    @State private var searchController = WorkspaceGridSearchController()
    @State private var remoteSearchState = RedisCollectionRemoteSearchState()
    @State private var collectionSortOrder = RedisCollectionSortOrder.descending
    @State private var collectionLoadScope = RedisCollectionLoadScope.more
    @State private var collectionLoadRevision = 0
    @State private var cancelsCollectionLoad = false
    @State private var isLoadingCollection = false
    @State private var showsLoadAllConfirmation = false
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var refreshRevision = 0
    @State private var cancelsRefresh = false
    @State private var commitRevision = 0
    @State private var isCommitting = false
    @State private var showsDisableSafetyLockConfirmation = false
    @State private var commitErrorMessage = ""
    @State private var showsCommitError = false
    @State private var showsDeleteConfirmation = false
    @State private var showsDeleteSafetyLockConfirmation = false
    @State private var deletionRevision = 0
    @State private var isDeleting = false
    @State private var deletionErrorMessage = ""
    @State private var showsDeletionError = false
    @State private var showsRenamePrompt = false
    @State private var renameDraft = ""
    @State private var pendingRenamePlan: RedisKeyRenamePlan?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            WorkspaceDatabaseDataProgressBar(
                isActive: isLoading || isLoadingCollection
                    || isCommitting || isDeleting,
                accessibilityLabel: AppCopy.current.text(
                    "正在读取 Key",
                    "Loading key"
                )
            )
            bottomBar
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
        .task(id: refreshRevision) {
            guard !cancelsRefresh else { return }
            await load()
        }
        .task(id: remoteSearchState.revision) {
            guard remoteSearchState.revision > 0 else { return }
            requestCollectionLoad(.replace)
        }
        .task(id: collectionLoadRevision) {
            guard collectionLoadRevision > 0, !cancelsCollectionLoad else {
                return
            }
            await loadCollection(scope: collectionLoadScope)
        }
        .task(id: commitRevision) {
            guard commitRevision > 0 else { return }
            await commitChanges()
        }
        .task(id: deletionRevision) {
            guard deletionRevision > 0 else { return }
            await deleteKey()
        }
        .onAppear {
            publishRedisKeyActions()
            publishContentRefreshActions()
            publishInspectorContext()
            publishPendingChangesActions()
        }
        .onChange(of: contentRefreshActions) { _, actions in
            if let actions {
                contentRefreshRegistry.update(actions, for: contentID)
            } else {
                contentRefreshRegistry.remove(for: contentID)
            }
        }
        .onChange(of: pendingChangesActions) { _, actions in
            if let actions {
                pendingChangesRegistry.update(actions, for: contentID)
            } else {
                pendingChangesRegistry.remove(for: contentID)
            }
        }
        .onChange(of: inspectorContext) { _, context in
            inspectorRegistry.update(.redisKey(context), for: contentID)
        }
        .onDisappear {
            redisKeyActionRegistry.remove(for: contentID)
            contentRefreshRegistry.remove(for: contentID)
            pendingChangesRegistry.remove(for: contentID)
            removeInspectorContext()
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $showsDisableSafetyLockConfirmation
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive
            ) {
                model.safetyLock.disable()
                startCommit()
            }
            .keyboardShortcut(.defaultAction)
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(safetyLockConfirmationMessage)
        }
        .alert(
            AppCopy.current.text("无法保存更改", "Unable to Save Changes"),
            isPresented: $showsCommitError
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(commitErrorMessage)
        }
        .alert(
            AppCopy.current.text("删除 Key？", "Delete Key?"),
            isPresented: $showsDeleteConfirmation
        ) {
            Button(
                AppCopy.current.text("删除", "Delete"),
                role: .destructive,
                action: requestDelete
            )
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $showsDeleteSafetyLockConfirmation
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive
            ) {
                model.safetyLock.disable()
                startDelete()
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(
                AppCopy.current.text(
                    "删除 Key 会永久移除其数据。安全锁将保持停用，直到此工作区关闭。",
                    "Deleting a key permanently removes its data. Safety Lock will remain disabled until this workspace closes."
                )
            )
        }
        .alert(
            AppCopy.current.text("无法删除 Key", "Unable to Delete Key"),
            isPresented: $showsDeletionError
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
        } message: {
            Text(deletionErrorMessage)
        }
        .alert(
            AppCopy.current.text("重命名 Key", "Rename Key"),
            isPresented: $showsRenamePrompt
        ) {
            TextField(
                AppCopy.current.text("Key 名称", "Key name"),
                text: $renameDraft
            )
            Button(
                AppCopy.current.text("重命名", "Rename"),
                action: requestRename
            )
            .disabled(
                renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                    || renameDraft == reference.name
            )
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(
                AppCopy.current.text(
                    "确认后会加入待提交修改。使用 RENAMENX，已有同名 Key 时不会覆盖。",
                    "This adds the rename to pending changes. RENAMENX prevents overwriting an existing key."
                )
            )
        }
        .alert(
            AppCopy.current.text("加载全部元素？", "Load All Elements?"),
            isPresented: $showsLoadAllConfirmation
        ) {
            Button(
                AppCopy.current.text("加载全部", "Load All"),
                action: startLoadAll
            )
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(loadAllConfirmationMessage)
        }
        .accessibilityIdentifier("redisKeyDetail.\(reference.id)")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(reference.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(reference.name)
                Text("DB \(reference.databaseIndex)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            RedisKeyHeaderActions(
                canRename: !hasPendingChanges && !isBusy,
                canCopySelectedRows: selectedRowsCommand != nil && !isBusy,
                canCopyWholeKey: wholeKeyCommand != nil && !isBusy,
                canDelete: !hasPendingChanges && !isBusy,
                rename: presentRename,
                copySelectedRows: copySelectedRowsAsCommand,
                copyWholeKey: copyWholeKeyAsCommand,
                delete: { showsDeleteConfirmation = true }
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(.bar)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let details, editor.usesPagedCollection {
            RedisCollectionBottomBar(
                details: details,
                editor: editor,
                searchState: remoteSearchState,
                sortOrder: $collectionSortOrder,
                isEnabled: !hasPendingChanges && !isCommitting && !isDeleting,
                isLoading: isLoading || isLoadingCollection,
                loadMore: requestLoadMore,
                loadAll: requestLoadAll,
                cancelLoad: cancelCollectionLoad,
                sortChanged: requestCollectionSort
            )
        } else {
            RedisKeyMetadataBar(
                details: details,
                searchController: editor.supportsRowEditing
                    ? searchController
                    : nil
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if let details {
            RedisKeyEditorView(
                details: details,
                editor: editor,
                isEnabled: !isLoading && !isLoadingCollection
                    && !isCommitting
                    && pendingRenamePlan == nil,
                searchController: searchController,
                remoteSearchState: remoteSearchState
            )
        } else if let errorMessage {
            ContentUnavailableView {
                Label(
                    AppCopy.current.text("无法读取 Key", "Unable to Load Key"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(errorMessage)
            } actions: {
                Button(
                    AppCopy.current.text("重试", "Retry"),
                    action: refresh
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loadedDetails = try await model.fetchRedisKeyDetails(reference)
            let collectionPage = try await initialCollectionPage(
                for: loadedDetails
            )
            let stringChunk = try await initialStringChunk(for: loadedDetails)
            applyLoadedDetails(
                loadedDetails,
                collectionPage: collectionPage,
                stringChunk: stringChunk
            )
            await model.resolveRedisKeyReference(loadedDetails.reference)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func initialStringChunk(
        for details: RedisKeyDetails
    ) async throws -> RedisStringChunk? {
        guard details.reference.type == .string else { return nil }
        return try await model.fetchRedisStringChunk(
            details.reference,
            offset: 0,
            maximumBytes: 65_536
        )
    }

    private func initialCollectionPage(
        for details: RedisKeyDetails
    ) async throws -> RedisCollectionPage? {
        guard isPagedCollection(details.reference.type) else { return nil }
        remoteSearchState.configure(for: details.reference.type)
        return try await model.fetchRedisCollectionPage(
            RedisCollectionQuery(
                reference: details.reference,
                limit: 500,
                search: remoteSearchState.submittedSearch,
                sortOrder: collectionSortOrder
            )
        )
    }

    private func isPagedCollection(_ type: RedisKeyType) -> Bool {
        switch type {
        case .list, .hash, .set, .sortedSet: true
        case .string, .stream, .module, .unknown, .none: false
        }
    }

    private func requestLoadMore() {
        guard editor.canLoadMoreCollectionRows else { return }
        requestCollectionLoad(.more)
    }

    private func requestLoadAll() {
        guard editor.canLoadMoreCollectionRows else { return }
        let remaining = max(
            0,
            (editor.collectionTotalCount ?? 0) - editor.collectionScannedCount
        )
        if remaining > 50_000 {
            showsLoadAllConfirmation = true
        } else {
            startLoadAll()
        }
    }

    private func startLoadAll() {
        requestCollectionLoad(.all)
    }

    private func requestCollectionSort() {
        guard !hasPendingChanges else { return }
        requestCollectionLoad(.replace)
    }

    private func requestCollectionLoad(_ scope: RedisCollectionLoadScope) {
        guard !editor.hasChanges else { return }
        cancelsCollectionLoad = false
        collectionLoadScope = scope
        collectionLoadRevision &+= 1
    }

    private func cancelCollectionLoad() {
        guard isLoadingCollection else { return }
        cancelsCollectionLoad = true
        collectionLoadRevision &+= 1
    }

    private func loadCollection(
        scope: RedisCollectionLoadScope
    ) async {
        guard let details,
              isPagedCollection(details.reference.type),
              !editor.hasChanges,
              !isLoadingCollection
        else { return }
        isLoadingCollection = true
        defer { isLoadingCollection = false }
        do {
            var continuation = scope == .replace
                ? nil
                : editor.collectionContinuation
            repeat {
                try Task.checkCancellation()
                guard let page = try await model.fetchRedisCollectionPage(
                    RedisCollectionQuery(
                        reference: details.reference,
                        continuation: continuation,
                        limit: 500,
                        search: remoteSearchState.submittedSearch,
                        sortOrder: collectionSortOrder
                    )
                ) else { return }
                applyCollectionPage(page, replacing: scope == .replace)
                continuation = page.continuation
                if scope != .all || editor.rows.count >= 500_000 {
                    break
                }
            } while continuation != nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyCollectionPage(
        _ page: RedisCollectionPage,
        replacing: Bool
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            editor.loadCollectionPage(page, replacing: replacing)
        }
    }

    private var loadAllConfirmationMessage: String {
        let remaining = max(
            0,
            (editor.collectionTotalCount ?? 0) - editor.collectionScannedCount
        )
        return AppCopy.current.text(
            "还需扫描约 \(remaining.formatted()) 个元素。最多保留 500,000 行，可随时停止。",
            "About \(remaining.formatted()) elements remain. QueryCraft retains at most 500,000 rows and you can stop at any time."
        )
    }

    private var contentID: WorkspaceContentTabID {
        .redisKey(reference)
    }

    private var inspectorContext: WorkspaceRedisKeyInspectorContext {
        WorkspaceRedisKeyInspectorContext(
            reference: reference,
            details: details,
            errorMessage: errorMessage,
            retry: refresh
        )
    }

    private func refresh() {
        guard !editor.hasChanges else { return }
        cancelsRefresh = false
        refreshRevision &+= 1
    }

    private func cancelRefresh() {
        cancelsRefresh = true
        refreshRevision &+= 1
    }

    private var contentRefreshActions: WorkspaceContentRefreshActions? {
        if isLoadingCollection {
            return WorkspaceContentRefreshActions(
                title: AppCopy.current.text("停止加载", "Stop Loading"),
                isStopping: true,
                didComplete: false,
                perform: cancelCollectionLoad
            )
        }
        if isLoading {
            return WorkspaceContentRefreshActions(
                title: AppCopy.current.text("停止刷新", "Stop Refreshing"),
                isStopping: true,
                didComplete: false,
                perform: cancelRefresh
            )
        }
        guard !isLoading,
              !isCommitting,
              !isDeleting,
              !hasPendingChanges
        else { return nil }
        return WorkspaceContentRefreshActions(
            title: AppCopy.current.text("刷新 Key", "Refresh Key"),
            isStopping: false,
            didComplete: false,
            perform: refresh
        )
    }

    private func publishContentRefreshActions() {
        guard let contentRefreshActions else {
            contentRefreshRegistry.remove(for: contentID)
            return
        }
        contentRefreshRegistry.update(contentRefreshActions, for: contentID)
    }

    private var pendingChangesActions: WorkspacePendingChangesActions? {
        guard hasPendingChanges else { return nil }
        return WorkspacePendingChangesActions(
            hasChanges: true,
            redisCommands: pendingCommands,
            isCommitting: isCommitting,
            discard: discardPendingChanges,
            preview: {},
            commit: requestCommit
        )
    }

    private func publishPendingChangesActions() {
        guard let pendingChangesActions else {
            pendingChangesRegistry.remove(for: contentID)
            return
        }
        pendingChangesRegistry.update(pendingChangesActions, for: contentID)
    }

    private func requestCommit() {
        guard !isCommitting,
              !pendingCommands.isEmpty
        else { return }
        if model.safetyLock.isEnabled {
            showsDisableSafetyLockConfirmation = true
        } else {
            startCommit()
        }
    }

    private func startCommit() {
        guard !isCommitting else { return }
        commitRevision &+= 1
    }

    private func commitChanges() async {
        guard !isCommitting else { return }
        do {
            if let renamePlan = pendingRenamePlan {
                isCommitting = true
                defer { isCommitting = false }
                _ = try await model.renameRedisKey(
                    renamePlan.reference,
                    to: renamePlan.newName
                )
                return
            }
            let plan = try editor.mutationPlan()
            guard !plan.commands.isEmpty else { return }
            isCommitting = true
            defer { isCommitting = false }
            let resolvedReference = details?.reference ?? reference
            if let request = plan.optimisticRequest {
                try await model.commitRedisOptimisticMutation(
                    request,
                    previewCommands: plan.commands
                )
            } else {
                try await model.commitRedisKeyChanges(
                    plan.commands,
                    for: resolvedReference
                )
            }
            try Task.checkCancellation()
            let loadedDetails = try await model.fetchRedisKeyDetails(reference)
            try Task.checkCancellation()
            let page = try await initialCollectionPage(for: loadedDetails)
            let stringChunk = try await initialStringChunk(for: loadedDetails)
            applyLoadedDetails(
                loadedDetails,
                collectionPage: page,
                stringChunk: stringChunk
            )
            await model.resolveRedisKeyReference(loadedDetails.reference)
        } catch is CancellationError {
            return
        } catch {
            commitErrorMessage = error.localizedDescription
            showsCommitError = true
        }
    }

    private func applyLoadedDetails(
        _ loadedDetails: RedisKeyDetails,
        collectionPage: RedisCollectionPage? = nil,
        stringChunk: RedisStringChunk? = nil
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            editor.load(loadedDetails)
            if let collectionPage {
                editor.loadCollectionPage(collectionPage, replacing: true)
            }
            if let stringChunk {
                editor.loadStringChunk(stringChunk, replacing: true)
            }
            details = loadedDetails
        }
    }

    private var deleteConfirmationMessage: String {
        let pendingChangesMessage = hasPendingChanges
            ? AppCopy.current.text(
                "未保存的修改也会丢失。",
                "Unsaved changes will also be discarded."
            )
            : ""
        return AppCopy.current.text(
            "将永久删除 Key“\(reference.name)”，并关闭当前标签页。\(pendingChangesMessage)此操作无法撤销。",
            "This permanently deletes the “\(reference.name)” key and closes this tab. \(pendingChangesMessage)This action cannot be undone."
        )
    }

    private func requestDelete() {
        if model.safetyLock.isEnabled {
            showsDeleteSafetyLockConfirmation = true
        } else {
            startDelete()
        }
    }

    private func startDelete() {
        guard !isDeleting else { return }
        deletionRevision &+= 1
    }

    private func deleteKey() async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await model.deleteRedisKey(details?.reference ?? reference)
        } catch is CancellationError {
            return
        } catch {
            deletionErrorMessage = error.localizedDescription
            showsDeletionError = true
        }
    }

    private var isBusy: Bool {
        isLoading || isLoadingCollection || isCommitting || isDeleting
    }

    private func presentRename() {
        guard !hasPendingChanges, !isCommitting, !isDeleting else { return }
        renameDraft = reference.name
        showsRenamePrompt = true
    }

    private func publishRedisKeyActions() {
        redisKeyActionRegistry.update(
            WorkspaceRedisKeyActions(presentRename: presentRename),
            for: contentID
        )
    }

    private func requestRename() {
        let newName = renameDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !newName.isEmpty, newName != reference.name else { return }
        pendingRenamePlan = RedisKeyRenamePlan(
            reference: details?.reference ?? reference,
            newName: newName
        )
    }

    private var hasPendingChanges: Bool {
        editor.hasChanges || pendingRenamePlan != nil
    }

    private var safetyLockConfirmationMessage: String {
        if pendingRenamePlan != nil {
            return AppCopy.current.text(
                "提交后会使用 RENAMENX 重命名 Key，已有同名 Key 时不会覆盖。安全锁将在此工作区关闭前保持停用。",
                "Submitting renames the key with RENAMENX, which never overwrites an existing key. Safety Lock will remain disabled until this workspace closes."
            )
        }
        return AppCopy.current.text(
            "全部 Redis 修改会在一个 MULTI/EXEC 事务中按预览顺序连续执行。Redis 不会回滚执行期间已成功的命令。安全锁将在此工作区关闭前保持停用。",
            "All Redis changes will run consecutively in preview order within one MULTI/EXEC transaction. Redis does not roll back commands that already succeeded during execution. Safety Lock will remain disabled until this workspace closes."
        )
    }

    private var pendingCommands: [RedisCommandInvocation] {
        pendingRenamePlan.map { [$0.command] }
            ?? ((try? editor.mutationPlan().commands) ?? [])
    }

    private func discardPendingChanges() {
        pendingRenamePlan = nil
        editor.discard()
    }

    private var selectedRowsCommand: String? {
        guard let details else { return nil }
        return RedisKeyCommandExporter.selectedRows(
            details: details,
            editor: editor
        )
    }

    private var wholeKeyCommand: String? {
        guard let details,
              remoteSearchState.submittedSearch == nil
        else { return nil }
        return RedisKeyCommandExporter.wholeKey(
            details: details,
            editor: editor
        )
    }

    private func copySelectedRowsAsCommand() {
        copyToPasteboard(selectedRowsCommand)
    }

    private func copyWholeKeyAsCommand() {
        copyToPasteboard(wholeKeyCommand)
    }

    private func copyToPasteboard(_ command: String?) {
        guard let command else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func publishInspectorContext() {
        inspectorRegistry.update(.redisKey(inspectorContext), for: contentID)
    }

    private func removeInspectorContext() {
        inspectorRegistry.remove(for: contentID)
    }
}
