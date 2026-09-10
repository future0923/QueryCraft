import SwiftUI

struct RedisKeyEditorView: View {
    let details: RedisKeyDetails
    @Bindable var editor: RedisKeyEditorState
    let isEnabled: Bool
    let searchController: WorkspaceGridSearchController
    @Bindable var remoteSearchState: RedisCollectionRemoteSearchState

    var body: some View {
        VStack(spacing: 0) {
            if details.reference.type != .string {
                RedisKeyEditingBar(
                    keyType: details.reference.type,
                    editor: editor,
                    isEnabled: isEnabled
                )
                Divider()
            }

            if editor.usesPagedCollection {
                RedisCollectionRemoteSearchBar(
                    keyType: details.reference.type,
                    state: remoteSearchState,
                    isEnabled: isEnabled && !editor.hasChanges
                )
                .frame(height: remoteSearchState.isPresented ? nil : 0)
                .opacity(remoteSearchState.isPresented ? 1 : 0)
                .clipped()
                .accessibilityHidden(!remoteSearchState.isPresented)
            } else if editor.supportsRowEditing {
                WorkspaceGridSearchBar(controller: searchController)
                    .frame(
                        height: searchController.isPresented ? nil : 0
                    )
                    .opacity(searchController.isPresented ? 1 : 0)
                    .clipped()
                    .accessibilityHidden(!searchController.isPresented)
            }

            valueContent

            if let validationError = editor.validationError,
               editor.hasChanges
            {
                Label(
                    validationError.localizedDescription,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.bar)
            }

            if details.reference.type == .string
                && details.value.isTruncated
                && !editor.isStringFullyLoaded
            {
                Text(truncationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.bar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusedSceneValue(
            \.workspaceDatabaseDataRowActions,
            rowCommandActions
        )
        .focusedSceneValue(
            \.workspaceGridSearchActions,
            searchCommandActions
        )
        .background {
            WorkspaceDatabaseDataRowKeyCommandHandler(
                actions: rowCommandActions,
                filterPresentationActions: nil,
                objectDetailTabActions: nil,
                isSuspended: false
            )
        }
    }

    @ViewBuilder
    private var valueContent: some View {
        switch details.reference.type {
        case .list where editor.usesPagedCollection:
            pagedCollectionGrid(kind: .list)
        case .string:
            RedisEditableStringValueView(
                editor: editor,
                isEnabled: isEnabled
            )
        case .hash:
            pagedCollectionGrid(
                kind: editor.supportsHashFieldExpiration
                    ? .hashWithFieldExpiration
                    : .hash
            )
        case .set:
            RedisEditableSetValueView(
                editor: editor,
                isEnabled: isEnabled,
                searchController: searchController,
                searchPresentationActions: collectionSearchCommandActions
            )
        case .sortedSet:
            RedisEditableSortedSetValueView(
                editor: editor,
                isEnabled: isEnabled,
                searchController: searchController,
                searchPresentationActions: collectionSearchCommandActions
            )
        case .list, .stream, .module, .unknown, .none:
            RedisKeyValueView(
                keyType: details.reference.type,
                snapshot: details.value
            )
        }
    }

    private func pagedCollectionGrid(
        kind: RedisCollectionGridKind
    ) -> some View {
        RedisCollectionGrid(
            rows: editor.rows,
            kind: kind,
            isEnabled: isEnabled,
            selectedRowIndexes: editor.selectedRowIndexes,
            searchController: searchController,
            searchPresentationActions: collectionSearchCommandActions,
            addRow: editor.addRow,
            updateValue: editor.updateRow,
            removeRow: editor.removeRow,
            selectRows: editor.selectRows
        )
    }

    private var truncationMessage: String {
        AppCopy.current.text(
            "String 仅显示前 64 KB，完整值保持只读。",
            "Only the first 64 KB is shown. The full string remains read-only."
        )
    }

    private var rowCommandActions: WorkspaceDatabaseDataRowCommandActions? {
        guard editor.supportsRowEditing else { return nil }
        let selectedRows = editor.selectedRowIndexes
        return WorkspaceDatabaseDataRowCommandActions(
            selectedRowIndexes: selectedRows,
            canAddRow: isEnabled,
            canDuplicateRow: false,
            canDeleteRow: isEnabled && !selectedRows.isEmpty,
            addRow: editor.addRow,
            duplicateRow: { _ in },
            deleteRows: editor.removeRows
        )
    }

    private var searchCommandActions: WorkspaceGridSearchCommandActions? {
        guard editor.supportsRowEditing else {
            return nil
        }
        if editor.usesPagedCollection {
            return collectionSearchCommandActions
        }
        guard searchController.canSearch else { return nil }
        return collectionSearchCommandActions
    }

    private var collectionSearchCommandActions:
        WorkspaceGridSearchCommandActions
    {
        if editor.usesPagedCollection {
            return WorkspaceGridSearchCommandActions(
                search: remoteSearchState.present,
                dismiss: remoteSearchState.dismiss,
                isPresented: { remoteSearchState.isPresented }
            )
        }
        return WorkspaceGridSearchCommandActions(
            search: searchController.present,
            dismiss: searchController.dismiss,
            isPresented: { searchController.isPresented }
        )
    }
}
