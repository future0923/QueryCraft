import SwiftUI

struct WorkspaceQueryResultView: View {
    let state: WorkspaceQueryExecutionState
    let statementResults: [WorkspaceStatementResult]
    @Binding var selectedStatementResultIndex: Int
    let elapsedSeconds: Double
    let currentDatabase: String?
    let databaseType: DatabaseType
    let safetyLock: WorkspaceSafetyLock
    let contentID: WorkspaceContentTabID
    let pendingChangesRegistry: WorkspacePendingChangesRegistry
    let fetchDetails: @MainActor (WorkspaceDatabaseObjectSelection) async throws
        -> WorkspaceDatabaseObjectDetails
    let applyChanges: @MainActor (WorkspaceDatabaseDataChangeSet) async throws
        -> Void
    let dismiss: () -> Void
    let updateInspectorContext:
        @MainActor (WorkspaceQueryResultInspectorContext) -> Void
    @State private var preferences = ApplicationPreferences.shared
    @State private var exportController = WorkspaceDataExportController()
    @State private var searchController = WorkspaceGridSearchController()
    @State private var pendingCellUpdates: [WorkspaceQueryResultPendingCellUpdate] = []
    @State private var detailsBySelection: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseObjectDetails
    ] = [:]
    @State private var detailsErrorBySelection: [
        WorkspaceDatabaseObjectSelection: String
    ] = [:]
    @State private var inspectorContext = WorkspaceQueryResultInspectorContext.empty
    @State private var isCommittingChanges = false
    @State private var changesTask: Task<Void, Never>?
    @State private var editErrorMessage = ""
    @State private var showsEditError = false
    @State private var showsDisableSafetyLock = false

    var body: some View {
        VStack(spacing: 0) {
            if statementResults.count > 1 {
                HStack {
                    WorkspaceStatementResultTabs(
                        results: statementResults,
                        selection: $selectedStatementResultIndex
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .frame(height: WorkspaceStatementResultTabs.height)

                Divider()
            }

            WorkspaceGridSearchBar(controller: searchController)
                .frame(
                    height: searchController.isPresented
                        ? nil
                        : 0
                )
                .opacity(searchController.isPresented ? 1 : 0)
                .clipped()
                .accessibilityHidden(!searchController.isPresented)

            Group {
                if let page = displayedState.page, !page.columns.isEmpty {
                    WorkspaceQueryResultTable(
                        page: page,
                        nullDisplayText:
                            preferences.tableNullDisplayStyle.displayText,
                        emptyStringDisplayText:
                            preferences
                            .tableEmptyStringDisplayStyle.displayText,
                        copyIncludesColumnNames:
                            preferences.copyIncludesColumnNames,
                        cellFont: preferences.dataGridFont(),
                        exportController: exportController,
                        searchController: searchController,
                        pendingUpdates: pendingUpdates(for: page),
                        cellEditRequest: { target in
                            cellEditRequest(for: target, page: page)
                        },
                        prepareCellEdit: { target in
                            prepareInlineCellEdit(target, page: page)
                        },
                        updateCellEdit: { context, mutation in
                            updateInlineCellEdit(
                                context,
                                mutation: mutation,
                                page: page
                            )
                        },
                        discardPendingUpdates: { updates in
                            discardPendingUpdates(updates, for: page)
                        },
                        updateInspectorContext: { context in
                            publishInspectorContext(context, page: page)
                        }
                    )
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WorkspaceDatabaseDataProgressBar(isActive: displayedState.isRunning)

            ZStack {
                HStack(spacing: 6) {
                    statusLabel
                    if displayedState != .idle {
                        Text("·")
                            .accessibilityHidden(true)
                        Text(
                            "\(displayedElapsedSeconds, format: .number.precision(.fractionLength(2))) s"
                        )
                    }
                }
                .lineLimit(1)
                .monospacedDigit()

                HStack {
                    HStack(spacing: 8) {
                        if displayedState.page?.rowCount ?? 0 > 0 {
                            WorkspaceGridSearchControl(
                                controller: searchController
                            )

                            if !state.isRunning {
                                WorkspaceDataExportControl(
                                    controller: exportController
                                )
                            }
                        }
                    }
                    .foregroundStyle(.primary)

                    Spacer()

                    if !state.isRunning {
                        Button(
                            AppCopy.current.text(
                                "关闭结果",
                                "Close Results"
                            ),
                            systemImage: "xmark",
                            action: dismiss
                        )
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(
                            AppCopy.current.text(
                                "关闭结果",
                                "Close Results"
                            )
                        )
                        .accessibilityIdentifier("closeQueryResultsButton")
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusedSceneValue(
            \.workspaceDataExportActions,
            exportCommandActions
        )
        .focusedSceneValue(
            \.workspaceGridSearchActions,
            searchCommandActions
        )
        .onChange(of: displayedState.page?.store.id, initial: true) {
            _, resultID in
            if resultID == nil {
                searchController.clearSource()
                searchController.dismiss()
            }
            updateInspectorContext(
                WorkspaceQueryResultInspectorContext(page: displayedState.page)
            )
        }
        .onChange(of: pendingCellUpdates, initial: true) { _, _ in
            publishPendingChangesActions()
        }
        .onChange(of: isCommittingChanges) { _, _ in
            publishPendingChangesActions()
        }
        .task(id: displayedState.page?.revision) {
            await preloadEditableDetails()
        }
        .alert(
            AppCopy.current.text("无法修改查询结果", "Unable to Edit Query Result"),
            isPresented: $showsEditError
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(editErrorMessage)
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $showsDisableSafetyLock
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive
            ) {
                safetyLock.disable()
                commitPendingChanges()
            }
            .keyboardShortcut(.defaultAction)
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(
                AppCopy.current.text(
                    "查询结果的待处理修改会在一个事务中写入基础表。安全锁将在此工作区关闭前保持停用。",
                    "Pending query-result changes will be written to the base table in one transaction. Safety Lock will remain disabled until this workspace closes."
                )
            )
        }
        .onDisappear {
            changesTask?.cancel()
            pendingChangesRegistry.remove(for: contentID)
        }
        .accessibilityIdentifier("queryResultPane")
    }

    @ViewBuilder
    private var emptyState: some View {
        switch displayedState {
        case .idle:
            ContentUnavailableView(
                statementResults.isEmpty
                    ? AppCopy.current.text("暂无结果", "No Results")
                    : AppCopy.current.text("等待执行", "Pending"),
                systemImage: statementResults.isEmpty ? "tablecells" : "clock",
                description: Text(
                    statementResults.isEmpty
                        ? AppCopy.current.text(
                            "运行 SQL 语句后即可查看结果。",
                            "Run a SQL statement to see its result."
                        )
                        : AppCopy.current.text(
                            "此语句尚未运行。",
                            "This statement has not run yet."
                        )
                )
            )
        case .running:
            ProgressView(AppCopy.current.text("正在执行查询…", "Executing query..."))
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .stopped:
            ContentUnavailableView(
                AppCopy.current.text("查询已停止", "Query Stopped"),
                systemImage: "stop.circle",
                description: Text(
                    AppCopy.current.text("未收到任何行。", "No rows were received.")
                )
            )
        case let .completed(page):
            ContentUnavailableView(
                AppCopy.current.text("没有数据行", "No Rows"),
                systemImage: "tablecells",
                description: Text(
                    page.columns.isEmpty
                        ? AppCopy.current.text(
                            "语句已完成，但没有返回行结果。",
                            "The statement completed without a row result."
                        )
                        : AppCopy.current.text(
                            "查询未返回任何行。",
                            "The query returned no rows."
                        )
                )
            )
        case let .failed(message, _):
            ContentUnavailableView {
                Label(
                    AppCopy.current.text("查询失败", "Query Failed"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(message)
            }
        case let .skipped(reason):
            ContentUnavailableView(
                AppCopy.current.text("已跳过语句", "Statement Skipped"),
                systemImage: "forward.end",
                description: Text(reason)
            )
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch displayedState {
        case .idle:
            Text(AppCopy.current.ready)
        case let .running(page):
            Text(
                AppCopy.current.text(
                    "正在获取 \(page?.rowCount ?? 0) 行…",
                    "Fetching \(page?.rowCount ?? 0) rows..."
                )
            )
                .monospacedDigit()
        case let .stopped(page):
            Label(
                AppCopy.current.text(
                    "已停止，共 \(page?.rowCount ?? 0) 行",
                    "Stopped at \(page?.rowCount ?? 0) rows"
                ),
                systemImage: "stop.fill"
            )
            .monospacedDigit()
        case let .completed(page):
            Text(AppCopy.current.rowCount(page.rowCount))
                .monospacedDigit()
        case let .failed(message, page):
            Label(
                page.map {
                    AppCopy.current.text(
                        "\($0.rowCount) 行 - \(message)",
                        "\($0.rowCount) rows - \(message)"
                    )
                } ?? message,
                systemImage: "exclamationmark.triangle"
            )
            .lineLimit(1)
        case let .skipped(reason):
            Label(reason, systemImage: "forward.end")
                .lineLimit(1)
        }
    }

    private var displayedResult: WorkspaceStatementResult? {
        guard statementResults.indices.contains(selectedStatementResultIndex)
        else {
            return nil
        }
        return statementResults[selectedStatementResultIndex]
    }

    private var displayedState: WorkspaceQueryExecutionState {
        displayedResult?.state ?? state
    }

    private var displayedElapsedSeconds: Double {
        displayedResult?.elapsedSeconds ?? elapsedSeconds
    }

    private var exportCommandActions: WorkspaceDataExportCommandActions? {
        guard displayedState.page?.rowCount ?? 0 > 0 else { return nil }
        return WorkspaceDataExportCommandActions(
            export: { exportController.presentOptions() }
        )
    }

    private var searchCommandActions: WorkspaceGridSearchCommandActions? {
        guard displayedState.page?.rowCount ?? 0 > 0 else { return nil }
        return WorkspaceGridSearchCommandActions(
            search: searchController.present
        )
    }

    private func pendingUpdates(
        for page: WorkspaceQueryResultPage
    ) -> [WorkspaceDatabaseInspectorPendingUpdate] {
        pendingCellUpdates.filter { $0.resultID == page.store.id }
            .map(\.pendingUpdate)
    }

    private func publishInspectorContext(
        _ context: WorkspaceQueryResultInspectorContext,
        page: WorkspaceQueryResultPage
    ) {
        inspectorContext = context
        guard let selection = editableSelection(for: page),
              let details = detailsBySelection[selection] else {
            updateInspectorContext(context)
            return
        }
        updateInspectorContext(
            context.withDataEditing(
                details: details,
                selection: selection,
                pendingUpdates: pendingUpdates(for: page),
                isUpdatingValue: isCommittingChanges,
                applyMutation: { field, mutation in
                    guard case let .loaded(rowIndexes, dataColumnIndex) =
                        field.source,
                        let rowIndex = rowIndexes.first
                    else { return }
                    let inlineContext = WorkspaceDatabaseDataCellInlineEditContext(
                        rowIndex: rowIndex,
                        dataColumnIndex: dataColumnIndex,
                        columnName: field.name,
                        initialText: field.editableText,
                        initialMutation: mutation
                    )
                    updateInlineCellEdit(
                        inlineContext,
                        mutation: mutation,
                        page: page
                    )
                }
            )
        )
    }

    private func prepareInlineCellEdit(
        _ target: WorkspaceDatabaseDataCellEditTarget,
        page: WorkspaceQueryResultPage
    ) -> WorkspaceDatabaseDataCellInlineEditContext? {
        guard !isCommittingChanges else { return nil }
        guard
            let selection = editableSelection(for: page)
        else {
            return nil
        }
        if let pendingSelection = pendingCellUpdates.first?.pendingUpdate.update.selection,
           pendingSelection != selection
        {
            presentEditError(
                AppCopy.current.text(
                    "请先提交或放弃当前基础表的待处理修改。",
                    "Commit or discard the pending changes for the current base table first."
                )
            )
            return nil
        }
        guard let details = detailsBySelection[selection] else {
            if let message = detailsErrorBySelection[selection] {
                presentEditError(message)
            }
            return nil
        }
        do {
            return try WorkspaceLoadedDataCellEditing.inlineContext(
                selection: selection,
                target: target,
                details: details,
                pendingUpdates: pendingCellUpdates.filter {
                    $0.resultID == page.store.id
                }.map(\.pendingUpdate)
            )
        } catch {
            presentEditError(error.localizedDescription)
            return nil
        }
    }

    private func cellEditRequest(
        for target: WorkspaceDatabaseDataCellEditTarget,
        page: WorkspaceQueryResultPage
    ) -> WorkspaceDatabaseDataCellEditRequest? {
        guard !isCommittingChanges,
              target.column?.origin != nil,
              let selection = editableSelection(for: page)
        else {
            return nil
        }
        if let pendingSelection = pendingCellUpdates.first?.pendingUpdate.update.selection,
           pendingSelection != selection
        {
            return nil
        }
        guard let details = detailsBySelection[selection] else { return nil }
        return try? WorkspaceDatabaseDataCellEditRequest.make(
            selection: selection,
            target: target,
            details: details
        )
    }

    private func updateInlineCellEdit(
        _ context: WorkspaceDatabaseDataCellInlineEditContext,
        mutation: WorkspaceDatabaseInspectorMutation,
        page: WorkspaceQueryResultPage
    ) {
        guard
            let selection = editableSelection(for: page),
            let details = detailsBySelection[selection],
            let row = page.cachedRow(at: context.rowIndex)
        else { return }
        let target = WorkspaceDatabaseDataCellEditTarget(
            rowIndex: context.rowIndex,
            dataColumnIndex: context.dataColumnIndex,
            columns: page.columns,
            row: row
        )
        do {
            let request = try WorkspaceDatabaseDataCellEditRequest.make(
                selection: selection,
                target: target,
                details: details
            )
            let update = try WorkspaceLoadedDataCellEditing.update(
                request: request,
                mutation: mutation
            )
            stageCellUpdate(
                update,
                target: target,
                resultID: page.store.id
            )
        } catch WorkspaceDatabaseDataCellEditError.unchangedValue {
            pendingCellUpdates.removeAll {
                $0.resultID == page.store.id
                    && $0.pendingUpdate.applies(
                        to: row,
                        columns: page.columns,
                        dataColumnIndex: context.dataColumnIndex
                    )
            }
        } catch {
            presentEditError(error.localizedDescription)
        }
    }

    private func stageCellUpdate(
        _ update: WorkspaceDatabaseDataCellUpdate,
        target: WorkspaceDatabaseDataCellEditTarget,
        resultID: UUID
    ) {
        let pending = WorkspaceQueryResultPendingCellUpdate(
            resultID: resultID,
            rowIndex: target.rowIndex,
            dataColumnIndex: target.dataColumnIndex,
            pendingUpdate: WorkspaceDatabaseInspectorPendingUpdate(update: update)
        )
        if let index = pendingCellUpdates.firstIndex(where: {
            $0.resultID == resultID && $0.matches(update)
        }) {
            pendingCellUpdates[index] = pending
        } else {
            pendingCellUpdates.append(pending)
        }
    }

    private func discardPendingUpdates(
        _ updates: [WorkspaceDatabaseInspectorPendingUpdate],
        for page: WorkspaceQueryResultPage
    ) {
        guard !isCommittingChanges, !updates.isEmpty else { return }
        pendingCellUpdates.removeAll { pending in
            pending.resultID == page.store.id
                && updates.contains(pending.pendingUpdate)
        }
    }

    private func preloadEditableDetails() async {
        guard let page = displayedState.page,
              let selection = editableSelection(for: page),
              detailsBySelection[selection] == nil else { return }
        do {
            let details = try await fetchDetails(selection)
            try Task.checkCancellation()
            detailsBySelection[selection] = details
            detailsErrorBySelection[selection] = nil
            publishInspectorContext(inspectorContext, page: page)
        } catch is CancellationError {
            return
        } catch {
            detailsErrorBySelection[selection] = error.localizedDescription
        }
    }

    private func editableSelection(
        for page: WorkspaceQueryResultPage
    ) -> WorkspaceDatabaseObjectSelection? {
        WorkspaceQueryResultEditing.selection(
            for: page,
            currentDatabase: currentDatabase
        )
    }

    private var pendingChangesActions: WorkspacePendingChangesActions? {
        guard !pendingCellUpdates.isEmpty else { return nil }
        let changeSet = WorkspaceDatabaseDataChangeSet(
            updates: pendingCellUpdates.map(\.pendingUpdate.update),
            inserts: [],
            deletes: []
        )
        let statements = changeSet.rowUpdates.compactMap {
            try? WorkspaceSQLPreviewStatement.make(
                rowUpdate: $0,
                databaseType: databaseType
            )
        }
        return WorkspacePendingChangesActions(
            hasChanges: true,
            statements: statements,
            isCommitting: isCommittingChanges,
            discard: discardPendingChanges,
            preview: {},
            commit: requestCommitPendingChanges
        )
    }

    private func publishPendingChangesActions() {
        if let pendingChangesActions {
            pendingChangesRegistry.update(pendingChangesActions, for: contentID)
        } else {
            pendingChangesRegistry.remove(for: contentID)
        }
    }

    private func discardPendingChanges() {
        guard !isCommittingChanges else { return }
        pendingCellUpdates.removeAll()
    }

    private func requestCommitPendingChanges() {
        guard !pendingCellUpdates.isEmpty, !isCommittingChanges else { return }
        if safetyLock.isEnabled {
            showsDisableSafetyLock = true
        } else {
            commitPendingChanges()
        }
    }

    private func commitPendingChanges() {
        guard !pendingCellUpdates.isEmpty, !isCommittingChanges else { return }
        let capturedUpdates = pendingCellUpdates
        let changeSet = WorkspaceDatabaseDataChangeSet(
            updates: capturedUpdates.map(\.pendingUpdate.update),
            inserts: [],
            deletes: []
        )
        isCommittingChanges = true
        changesTask = Task { @MainActor in
            defer {
                isCommittingChanges = false
                changesTask = nil
            }
            do {
                try await applyChanges(changeSet)
                pendingCellUpdates.removeAll { capturedUpdates.contains($0) }
                do {
                    for (resultID, updates) in Dictionary(
                        grouping: capturedUpdates,
                        by: \.resultID
                    ) {
                        guard let store = resultStore(identifiedBy: resultID) else {
                            continue
                        }
                        try await store.apply(updates.map(\.mutation))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    presentEditError(
                        AppCopy.current.text(
                            "修改已保存到数据库，但无法刷新当前查询结果。请重新运行查询。\n\n\(error.localizedDescription)",
                            "The changes were saved to the database, but the current query result could not be refreshed. Run the query again.\n\n\(error.localizedDescription)"
                        )
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                presentEditError(error.localizedDescription)
            }
        }
    }

    private func resultStore(identifiedBy id: UUID) -> WorkspaceQueryResultStore? {
        statementResults.lazy.compactMap(\.state.page).first {
            $0.store.id == id
        }?.store ?? (state.page?.store.id == id ? state.page?.store : nil)
    }

    private func presentEditError(_ message: String) {
        editErrorMessage = message
        showsEditError = true
    }
}
