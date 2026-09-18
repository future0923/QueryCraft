import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class WorkspaceRedisNewKeyDraft: Identifiable {
    static let creatableTypes: [RedisKeyType] = [
        .string, .hash, .list, .set, .sortedSet,
    ]

    let id: UUID
    let databaseIndex: Int
    let keyType: RedisKeyType
    var name = ""
    var editor = RedisKeyEditorState()

    private let didCreate: @MainActor (UUID, RedisKeyReference) -> Void

    init(
        id: UUID = UUID(),
        databaseIndex: Int,
        type: RedisKeyType,
        didCreate: @escaping @MainActor (
            UUID,
            RedisKeyReference
        ) -> Void = { _, _ in }
    ) {
        self.id = id
        self.databaseIndex = databaseIndex
        keyType = type
        self.didCreate = didCreate
        editor.configureAsNewKey(databaseIndex: databaseIndex, type: type)
    }

    var title: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty
            ? AppCopy.current.text("新增 Key", "New Key")
            : trimmedName
    }

    var hasContent: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !editor.rows.isEmpty
            || !editor.stringValue.isEmpty
            || editor.expirationMode == .expires
    }

    var validationError: RedisKeyEditError? {
        do {
            _ = try makeCreationPlan()
            return nil
        } catch let error as RedisKeyEditError {
            return error
        } catch {
            return .unavailable
        }
    }

    var creationPlan: RedisKeyCreationPlan? {
        try? makeCreationPlan()
    }

    func makeCreationPlan() throws -> RedisKeyCreationPlan {
        try RedisKeyCreationPlan.make(
            databaseIndex: databaseIndex,
            name: name,
            type: keyType,
            stringValue: editor.stringValue,
            rows: editor.rows,
            expirationMode: editor.expirationMode,
            ttlMillisecondsText: editor.ttlMillisecondsText
        )
    }

    func reset() {
        name = ""
        editor.configureAsNewKey(databaseIndex: databaseIndex, type: keyType)
    }

    func complete(with reference: RedisKeyReference) {
        didCreate(id, reference)
    }
}

struct WorkspaceRedisNewKeyDetailView: View {
    @Bindable var draft: WorkspaceRedisNewKeyDraft
    let model: WorkspaceModel
    let pendingChangesRegistry: WorkspacePendingChangesRegistry

    @State private var searchController = WorkspaceGridSearchController()
    @State private var showsDisableSafetyLockConfirmation = false
    @State private var errorMessage: String?
    @State private var submissionTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if draft.keyType != .string {
                RedisKeyEditingBar(
                    keyType: draft.keyType,
                    editor: draft.editor,
                    isEnabled: !isSubmitting
                )
                Divider()
            }
            searchBar
            content
            validationBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusedSceneValue(\.workspaceGridSearchActions, searchCommandActions)
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
                submit()
            }
            .keyboardShortcut(.defaultAction)
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(
                AppCopy.current.text(
                    "创建 Key 会立即写入 Redis。安全锁将保持停用，直到此工作区关闭。",
                    "Creating a key writes it to Redis right away. Safety Lock will remain disabled until this workspace closes."
                )
            )
        }
        .alert(
            AppCopy.current.text("无法创建 Key", "Unable to Create Key"),
            isPresented: errorPresentation
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: publishPendingChangesActions)
        .onChange(of: pendingChangesActions) { _, _ in
            publishPendingChangesActions()
        }
        .onDisappear {
            submissionTask?.cancel()
            pendingChangesRegistry.remove(for: contentID)
        }
    }

    private var contentID: WorkspaceContentTabID {
        .redisNewKey(draft.id)
    }

    private var isSubmitting: Bool { submissionTask != nil }

    private var header: some View {
        HStack(spacing: 12) {
            TextField(
                AppCopy.current.text("Key 名称", "Key name"),
                text: $draft.name
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 180, maxWidth: 320)
            .disabled(isSubmitting)
            .accessibilityIdentifier("redisNewKeyNameField")

            Text(draft.keyType.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .accessibilityIdentifier("redisNewKeyTypeBadge")

            Spacer()

            Text("DB \(draft.databaseIndex)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(.bar)
    }

    @ViewBuilder
    private var searchBar: some View {
        if draft.editor.supportsRowEditing {
            WorkspaceGridSearchBar(controller: searchController)
                .frame(height: searchController.isPresented ? nil : 0)
                .opacity(searchController.isPresented ? 1 : 0)
                .clipped()
                .accessibilityHidden(!searchController.isPresented)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch draft.keyType {
        case .string:
            RedisEditableStringValueView(
                editor: draft.editor,
                isEnabled: !isSubmitting,
                allowsHex: false
            )
        case .list:
            collectionGrid(kind: .list)
        case .hash:
            collectionGrid(kind: .hash)
        case .set:
            RedisEditableSetValueView(
                editor: draft.editor,
                isEnabled: !isSubmitting,
                searchController: searchController,
                searchPresentationActions: collectionSearchCommandActions
            )
        case .sortedSet:
            RedisEditableSortedSetValueView(
                editor: draft.editor,
                isEnabled: !isSubmitting,
                searchController: searchController,
                searchPresentationActions: collectionSearchCommandActions
            )
        case .stream, .module, .none, .unknown:
            EmptyView()
        }
    }

    private func collectionGrid(
        kind: RedisCollectionGridKind
    ) -> some View {
        RedisCollectionGrid(
            rows: draft.editor.rows,
            kind: kind,
            isEnabled: !isSubmitting,
            selectedRowIndexes: draft.editor.selectedRowIndexes,
            searchController: searchController,
            searchPresentationActions: collectionSearchCommandActions,
            addRow: draft.editor.addRow,
            updateValue: draft.editor.updateRow,
            removeRow: draft.editor.removeRow,
            selectRows: draft.editor.selectRows
        )
    }

    @ViewBuilder
    private var validationBar: some View {
        if draft.hasContent, let validationError = draft.validationError {
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
    }

    private var pendingChangesActions: WorkspacePendingChangesActions? {
        guard draft.hasContent else { return nil }
        return WorkspacePendingChangesActions(
            hasChanges: true,
            redisCommands: draft.creationPlan?.commands ?? [],
            canCommit: draft.validationError == nil,
            isCommitting: isSubmitting,
            discard: discardDraft,
            preview: {},
            commit: requestCommit
        )
    }

    private var searchCommandActions: WorkspaceGridSearchCommandActions? {
        guard draft.editor.supportsRowEditing,
              searchController.canSearch
        else { return nil }
        return collectionSearchCommandActions
    }

    private var collectionSearchCommandActions:
        WorkspaceGridSearchCommandActions
    {
        WorkspaceGridSearchCommandActions(
            search: searchController.present,
            dismiss: searchController.dismiss,
            isPresented: { searchController.isPresented }
        )
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private func publishPendingChangesActions() {
        guard let pendingChangesActions else {
            pendingChangesRegistry.remove(for: contentID)
            return
        }
        pendingChangesRegistry.update(pendingChangesActions, for: contentID)
    }

    private func discardDraft() {
        guard !isSubmitting else { return }
        draft.reset()
    }

    private func requestCommit() {
        guard !isSubmitting, draft.validationError == nil else { return }
        if model.safetyLock.isEnabled {
            showsDisableSafetyLockConfirmation = true
        } else {
            submit()
        }
    }

    private func submit() {
        guard submissionTask == nil,
              let plan = draft.creationPlan
        else { return }
        submissionTask = Task { @MainActor in
            defer { submissionTask = nil }
            do {
                let reference = try await model.createRedisKey(plan)
                try Task.checkCancellation()
                draft.complete(with: reference)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
