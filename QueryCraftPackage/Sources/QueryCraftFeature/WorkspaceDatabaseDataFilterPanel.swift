import AppKit
import SwiftUI

struct WorkspaceDatabaseDataFilterPanel: View {
    let detailsState: WorkspaceDatabaseObjectDetailsState
    @Bindable var editor: WorkspaceDatabaseDataFilterEditor
    let retryDetails: () -> Void
    let close: @MainActor @Sendable () -> Void
    let clearAndClose: () -> Void
    let apply: () -> Void
    @FocusState private var focusedField: WorkspaceDatabaseDataFilterFocus?
    @State private var activeConditionID: UUID?
    @State private var presentedPicker: WorkspaceDatabaseDataFilterFocus?
    @State private var pendingCommand: WorkspaceDatabaseDataFilterPendingCommand?
    @State private var columnPresentationRequests: [UUID: Int] = [:]
    @State private var operatorPresentationRequests: [UUID: Int] = [:]
    @State private var columnDismissalRequests: [UUID: Int] = [:]
    @State private var operatorDismissalRequests: [UUID: Int] = [:]
    @State private var conditionRemovalTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            conditionContent

            HStack(spacing: 8) {
                if !isElasticsearch {
                    Picker(
                        AppCopy.current.text("匹配方式", "Match Mode"),
                        selection: $editor.draft.logic
                    ) {
                        ForEach(
                            WorkspaceDatabaseDataFilterLogic.allCases,
                            id: \.self
                        ) {
                            Text($0.title).tag($0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.regular)
                    .fixedSize()
                }

                WorkspaceDatabaseDataFilterShortcutHints(
                    showsToggleCondition: !isElasticsearch
                )
                    .frame(maxWidth: .infinity)

                Text(
                    AppCopy.current.text(
                        "\(editor.draft.conditions.count) 条条件",
                        "\(editor.draft.conditions.count) conditions"
                    )
                )
                .foregroundStyle(.secondary)

                Button(
                    AppCopy.current.text("清除", "Clear"),
                    action: clearAndClose
                )
                .disabled(editor.draft.conditions.isEmpty)

                Button(
                    AppCopy.current.text("全部应用", "Apply All"),
                    action: apply
                )
                .disabled(!editor.draft.isValid)

                WorkspaceInlineIconButton(
                    systemImageName: "chevron.up",
                    title: AppCopy.current.text(
                        "关闭筛选",
                        "Close Filter"
                    ),
                    action: close
                )
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background {
            WorkspaceDatabaseDataFilterKeyCommandHandler(actions: commandActions)
                .allowsHitTesting(false)
        }
        .onExitCommand(perform: closeFilterIfPossible)
        .focusedSceneValue(
            \.workspaceDatabaseDataFilterActions,
            commandActions
        )
        .onAppear {
            activeConditionID = editor.draft.conditions.first?.id
        }
        .task {
            await Task.yield()
            guard
                focusedField == nil,
                let conditionID = editor.draft.conditions.first?.id
            else {
                return
            }
            focusedField = preferredEditingFocus(for: conditionID)
        }
        .onChange(of: focusedField) { _, focusedField in
            guard let focusedField else { return }
            activeConditionID = focusedField.conditionID
        }
        .onDisappear {
            conditionRemovalTask?.cancel()
            conditionRemovalTask = nil
        }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("databaseDataFilterPanel")
    }

    @ViewBuilder
    private var conditionContent: some View {
        switch detailsState {
        case .notLoaded, .loading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(AppCopy.current.text("正在加载列…", "Loading columns..."))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
        case let .failed(message):
            HStack {
                Label(
                    AppCopy.current.text("无法加载列", "Unable to Load Columns"),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(
                    AppCopy.current.text("重试", "Retry"),
                    systemImage: "arrow.clockwise",
                    action: retryDetails
                )
            }
            .controlSize(.small)
            .padding(8)
        case .loaded:
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if isElasticsearch {
                            Grid(horizontalSpacing: 8, verticalSpacing: 4) {
                                ForEach($editor.draft.conditions) { condition in
                                    elasticsearchConditionRow(condition)
                                        .id(condition.wrappedValue.id)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            VStack(spacing: 4) {
                                ForEach($editor.draft.conditions) { condition in
                                    relationalConditionRow(condition)
                                        .id(condition.wrappedValue.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(height: conditionListHeight)
                .scrollDisabled(editor.draft.conditions.count <= 7)
                .task(id: activeConditionID) {
                    await Task.yield()
                    guard
                        let conditionID = activeConditionID,
                        editor.draft.conditions.contains(
                            where: { $0.id == conditionID }
                        )
                    else {
                        return
                    }
                    proxy.scrollTo(conditionID, anchor: .center)
                }
            }
        }
    }

    private var columns: [WorkspaceDatabaseColumn] {
        guard case let .loaded(details) = detailsState else { return [] }
        if let fields = details.documentMappingFields {
            let filterablePaths = Set(
                fields.compactMap { $0.dataFilterKind == nil ? nil : $0.path }
            )
            return details.columns.filter { filterablePaths.contains($0.name) }
        }
        return details.columns
    }

    private var mappingFields: [WorkspaceDocumentMappingField] {
        guard case let .loaded(details) = detailsState else { return [] }
        return details.documentMappingFields ?? []
    }

    private var isElasticsearch: Bool {
        if case let .loaded(details) = detailsState {
            return details.documentMappingFields != nil
        }
        return editor.draft.usesElasticsearchConditions
    }

    private func relationalConditionRow(
        _ condition: Binding<WorkspaceDatabaseDataFilterCondition>
    ) -> some View {
        WorkspaceDatabaseDataFilterConditionRow(
            condition: condition,
            columns: columns,
            mappingFields: mappingFields,
            focusedField: $focusedField,
            columnPresentationRequest: columnPresentationRequests[
                condition.wrappedValue.id,
                default: 0
            ],
            operatorPresentationRequest: operatorPresentationRequests[
                condition.wrappedValue.id,
                default: 0
            ],
            columnDismissalRequest: columnDismissalRequests[
                condition.wrappedValue.id,
                default: 0
            ],
            operatorDismissalRequest: operatorDismissalRequests[
                condition.wrappedValue.id,
                default: 0
            ],
            columnPresentationChanged: {
                updatePickerPresentation(
                    .column(condition.wrappedValue.id),
                    isPresented: $0
                )
            },
            operatorPresentationChanged: {
                updatePickerPresentation(
                    .operation(condition.wrappedValue.id),
                    isPresented: $0
                )
            },
            add: { addCondition(after: condition.wrappedValue.id) },
            remove: { removeCondition(id: condition.wrappedValue.id) }
        )
    }

    private func elasticsearchConditionRow(
        _ condition: Binding<WorkspaceDatabaseDataFilterCondition>
    ) -> some View {
        WorkspaceElasticsearchDataFilterConditionRow(
            condition: condition,
            columns: columns,
            mappingFields: mappingFields,
            focusedField: $focusedField,
            columnPresentationRequest: columnPresentationRequests[
                condition.wrappedValue.id,
                default: 0
            ],
            operatorPresentationRequest: operatorPresentationRequests[
                condition.wrappedValue.id,
                default: 0
            ],
            columnDismissalRequest: columnDismissalRequests[
                condition.wrappedValue.id,
                default: 0
            ],
            operatorDismissalRequest: operatorDismissalRequests[
                condition.wrappedValue.id,
                default: 0
            ],
            columnPresentationChanged: {
                updatePickerPresentation(
                    .column(condition.wrappedValue.id),
                    isPresented: $0
                )
            },
            operatorPresentationChanged: {
                updatePickerPresentation(
                    .operation(condition.wrappedValue.id),
                    isPresented: $0
                )
            },
            add: { addCondition(after: condition.wrappedValue.id) },
            remove: { removeCondition(id: condition.wrappedValue.id) }
        )
    }

    private var conditionListHeight: CGFloat {
        let visibleConditionCount = min(editor.draft.conditions.count, 7)
        let rowHeights = CGFloat(visibleConditionCount) * 24
        let rowSpacing = CGFloat(max(visibleConditionCount - 1, 0)) * 4
        return rowHeights + rowSpacing + 8
    }

    private var commandActions: WorkspaceDatabaseDataFilterCommandActions {
        return WorkspaceDatabaseDataFilterCommandActions(
            canAddCondition: columns.first != nil,
            canRemoveCondition: activeCondition != nil,
            canApplyAll: editor.draft.isValid,
            canNavigateConditions: editor.draft.conditions.count > 1,
            canEditActiveCondition: activeCondition != nil,
            canToggleCondition: !isElasticsearch && activeCondition != nil,
            canCloseFilter: presentedPicker == nil,
            addCondition: { requestPanelCommand(.addCondition) },
            removeCondition: { requestPanelCommand(.removeCondition) },
            applyAll: { requestPanelCommand(.applyAll) },
            moveUp: { requestPanelCommand(.moveUp) },
            moveDown: { requestPanelCommand(.moveDown) },
            openColumnPicker: { requestPanelCommand(.openColumnPicker) },
            openOperatorPicker: { requestPanelCommand(.openOperatorPicker) },
            toggleCondition: { requestPanelCommand(.toggleCondition) },
            close: { requestPanelCommand(.closeFilter) }
        )
    }

    private var activeCondition: WorkspaceDatabaseDataFilterCondition? {
        guard let activeConditionID else { return editor.draft.conditions.first }
        return editor.draft.conditions.first { $0.id == activeConditionID }
    }

    private func addCondition(after conditionID: UUID? = nil) {
        guard let column = columns.first else { return }
        let mappingField = mappingFields.first { $0.path == column.name }
        let newCondition = column.defaultDataFilterCondition(
            mappingField: mappingField
        )
        if
            let conditionID,
            let index = editor.draft.conditions.firstIndex(
                where: { $0.id == conditionID }
            )
        {
            editor.draft.conditions.insert(newCondition, at: index + 1)
        } else {
            editor.draft.conditions.append(newCondition)
        }
        activeConditionID = newCondition.id
        focusedField = preferredEditingFocus(for: newCondition.id)
    }

    private func removeCondition(id: UUID) {
        let previousFocus = focusedField
        let removesLastCondition = editor.draft.conditions.count == 1
            && editor.draft.conditions.first?.id == id
        if previousFocus?.conditionID == id {
            focusedField = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
        }

        conditionRemovalTask?.cancel()
        conditionRemovalTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            if removesLastCondition {
                editor.draft = .empty
                activeConditionID = nil
                conditionRemovalTask = nil
                clearAndClose()
                return
            }
            guard let nextFocus = removeConditionNow(id: id) else {
                conditionRemovalTask = nil
                return
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedField = nextFocus
            conditionRemovalTask = nil
        }
    }

    private func removeConditionNow(
        id: UUID
    ) -> WorkspaceDatabaseDataFilterFocus? {
        guard
            let removedIndex = editor.draft.conditions.firstIndex(
                where: { $0.id == id }
            )
        else {
            return nil
        }

        let nextID: UUID
        editor.draft.conditions.remove(at: removedIndex)
        guard !editor.draft.conditions.isEmpty else { return nil }
        let nextIndex = min(
            removedIndex,
            editor.draft.conditions.count - 1
        )
        nextID = editor.draft.conditions[nextIndex].id

        activeConditionID = nextID
        return preferredEditingFocus(for: nextID)
    }

    private func removeActiveCondition() {
        guard let conditionID = activeCondition?.id else { return }
        removeCondition(id: conditionID)
    }

    private func applyAllConditions() {
        guard editor.draft.isValid else { return }
        apply()
    }

    private func moveActiveCondition(by offset: Int) {
        guard !editor.draft.conditions.isEmpty else { return }
        let currentID = activeCondition?.id ?? editor.draft.conditions[0].id
        let currentIndex = editor.draft.conditions.firstIndex {
            $0.id == currentID
        } ?? 0
        let nextIndex = min(
            max(currentIndex + offset, 0),
            editor.draft.conditions.count - 1
        )
        let nextID = editor.draft.conditions[nextIndex].id
        activeConditionID = nextID
        focusedField = preferredEditingFocus(for: nextID)
    }

    private func openActiveColumnPicker() {
        guard let conditionID = activeCondition?.id else { return }
        activeConditionID = conditionID
        columnPresentationRequests[conditionID, default: 0] &+= 1
    }

    private func openActiveOperatorPicker() {
        guard let conditionID = activeCondition?.id else { return }
        activeConditionID = conditionID
        operatorPresentationRequests[conditionID, default: 0] &+= 1
    }

    private func updatePickerPresentation(
        _ picker: WorkspaceDatabaseDataFilterFocus,
        isPresented: Bool
    ) {
        if isPresented {
            presentedPicker = picker
            activeConditionID = picker.conditionID
        } else if presentedPicker == picker {
            presentedPicker = nil
            focusedField = preferredEditingFocus(for: picker.conditionID)
            guard let pendingCommand else { return }
            self.pendingCommand = nil
            performPanelCommand(pendingCommand)
        }
    }

    private func requestPanelCommand(
        _ command: WorkspaceDatabaseDataFilterPendingCommand
    ) {
        guard let presentedPicker else {
            performPanelCommand(command)
            return
        }
        if commandTargetsPresentedPicker(command, picker: presentedPicker) {
            return
        }
        pendingCommand = command
        dismissPicker(presentedPicker)
    }

    private func performPanelCommand(
        _ command: WorkspaceDatabaseDataFilterPendingCommand
    ) {
        switch command {
        case .addCondition:
            addCondition(after: activeCondition?.id)
        case .removeCondition:
            removeActiveCondition()
        case .applyAll:
            applyAllConditions()
        case .moveUp:
            moveActiveCondition(by: -1)
        case .moveDown:
            moveActiveCondition(by: 1)
        case .openColumnPicker:
            openActiveColumnPicker()
        case .openOperatorPicker:
            openActiveOperatorPicker()
        case .toggleCondition:
            toggleActiveCondition()
        case .closeFilter:
            close()
        }
    }

    private func dismissPicker(_ picker: WorkspaceDatabaseDataFilterFocus) {
        switch picker {
        case let .column(conditionID):
            columnDismissalRequests[conditionID, default: 0] &+= 1
        case let .operation(conditionID):
            operatorDismissalRequests[conditionID, default: 0] &+= 1
        case .enabled, .elasticsearchClause, .value, .secondValue:
            break
        }
    }

    private func commandTargetsPresentedPicker(
        _ command: WorkspaceDatabaseDataFilterPendingCommand,
        picker: WorkspaceDatabaseDataFilterFocus
    ) -> Bool {
        switch (command, picker) {
        case (.openColumnPicker, .column),
             (.openOperatorPicker, .operation):
            true
        default:
            false
        }
    }

    private func closeFilterIfPossible() {
        guard presentedPicker == nil else { return }
        close()
    }

    private func toggleActiveCondition() {
        guard !isElasticsearch else { return }
        guard
            let conditionID = activeCondition?.id,
            let index = editor.draft.conditions.firstIndex(
                where: { $0.id == conditionID }
            )
        else {
            return
        }
        editor.draft.conditions[index].isEnabled.toggle()
        focusedField = preferredEditingFocus(for: conditionID)
    }

    private func preferredEditingFocus(
        for conditionID: UUID
    ) -> WorkspaceDatabaseDataFilterFocus {
        guard
            let condition = editor.draft.conditions.first(
                where: { $0.id == conditionID }
            )
        else {
            return .value(conditionID)
        }
        guard !isElasticsearch else {
            return condition.operation.requiresValue
                ? .value(conditionID)
                : .operation(conditionID)
        }
        guard condition.isEnabled else { return .enabled(conditionID) }
        return condition.operation.requiresValue
            ? .value(conditionID)
            : .operation(conditionID)
    }
}
