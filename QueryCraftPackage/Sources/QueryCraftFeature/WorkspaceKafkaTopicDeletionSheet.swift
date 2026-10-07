import SwiftUI

struct WorkspaceKafkaTopicDeletionSheet: View {
    let model: WorkspaceModel
    let didDelete: @MainActor (WorkspaceDatabaseObjectSelection) -> Void
    let dismiss: @MainActor () -> Void
    @State private var editor: WorkspaceKafkaTopicDeletionModel
    @State private var operation: Task<Void, Never>?
    @State private var showsUnlock = false
    @FocusState private var confirmationIsFocused: Bool

    init(selection: WorkspaceDatabaseObjectSelection, model: WorkspaceModel,
         didDelete: @escaping @MainActor (WorkspaceDatabaseObjectSelection) -> Void,
         dismiss: @escaping @MainActor () -> Void) {
        self.model = model
        self.didDelete = didDelete
        self.dismiss = dismiss
        _editor = State(initialValue: WorkspaceKafkaTopicDeletionModel(selection: selection))
    }

    private var busy: Bool { operation != nil }
    private var hasPendingChanges: Bool { model.kafkaHasPendingChanges(editor.selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppCopy.current.text("删除 Topic", "Delete Topic")).font(.title2.weight(.semibold))
            Text(AppCopy.current.text("将永久删除此 Topic 及其全部分区和消息。此操作无法撤销。",
                                      "This permanently deletes the topic, all its partitions and messages. This action cannot be undone."))
            Text(editor.selection.objectName).font(.body.monospaced()).textSelection(.enabled)
                .lineLimit(2).help(editor.selection.objectName)
            TextField(AppCopy.current.text("输入完整 Topic 名称以确认", "Enter the full topic name to confirm"), text: $editor.confirmation)
                .textFieldStyle(.roundedBorder).focused($confirmationIsFocused)
                .disabled(busy || editor.needsVerification)
                .accessibilityIdentifier("deleteKafkaTopicConfirmation")
            ScrollView {
                Text(hasPendingChanges ? WorkspaceKafkaTopicDeletionError.pendingChanges.localizedDescription
                     : editor.error ?? AppCopy.current.text("名称必须完全一致。", "The name must match exactly."))
                    .font(.callout).foregroundStyle(editor.error != nil || hasPendingChanges ? .red : .secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 64)
            WorkspaceDatabaseDataProgressBar(isActive: busy)
            HStack {
                Spacer()
                Button(AppCopy.current.text("取消", "Cancel"), role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction).disabled(busy)
                Button(AppCopy.current.text("删除 Topic", "Delete Topic"), role: .destructive) {
                    if model.safetyLock.isEnabled { showsUnlock = true } else { submit() }
                }
                .disabled(busy || !editor.canDelete || hasPendingChanges || model.connectionState != .connected)
                .accessibilityIdentifier("deleteKafkaTopicSubmit")
            }
        }
        .padding(20).frame(width: 540)
        .interactiveDismissDisabled(busy)
        .task { confirmationIsFocused = true }
        .alert(AppCopy.current.text("停用安全锁并删除 Topic？", "Disable Safety Lock and Delete Topic?"), isPresented: $showsUnlock) {
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
            Button(AppCopy.current.text("停用并删除", "Disable and Delete"), role: .destructive) {
                model.safetyLock.disable()
                submit()
            }
        } message: {
            Text(AppCopy.current.text("将永久删除 Topic “\(editor.selection.objectName)”及全部消息。安全锁将保持停用，直到此工作区关闭。",
                "Topic “\(editor.selection.objectName)” and all its messages will be permanently deleted. Safety Lock remains disabled until this workspace closes."))
        }
    }

    private func submit() {
        guard !busy, editor.canDelete, !hasPendingChanges else { return }
        // A dispatched admin write must retain its result, even on window teardown.
        operation = Task { @MainActor in
            defer { operation = nil }
            await editor.submit(using: model.deleteKafkaTopic)
            if editor.didDelete {
                didDelete(editor.selection)
                dismiss()
            }
        }
    }
}
