import SwiftUI

struct WorkspaceElasticsearchIndexDeletionSheet: View {
    let model: WorkspaceModel
    let didDelete: @MainActor (WorkspaceDatabaseObjectSelection) -> Void
    let dismiss: @MainActor () -> Void
    @State private var editor: WorkspaceElasticsearchIndexDeletionEditor
    @State private var operation: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    @State private var showsPreview = false
    @State private var showsResponse = false
    @State private var showsUnlockConfirmation = false
    @State private var didCloseObject = false
    @FocusState private var confirmationIsFocused: Bool

    init(selection: WorkspaceDatabaseObjectSelection, model: WorkspaceModel,
         didDelete: @escaping @MainActor (WorkspaceDatabaseObjectSelection) -> Void,
         dismiss: @escaping @MainActor () -> Void) {
        self.model = model
        self.didDelete = didDelete
        self.dismiss = dismiss
        _editor = State(initialValue: WorkspaceElasticsearchIndexDeletionEditor(selection: selection))
    }

    private var busy: Bool { operation != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppCopy.current.text("删除索引", "Delete Index"))
                .font(.title2.weight(.semibold))
            Text(AppCopy.current.text(
                "将永久删除以下索引及其中的全部文档。此操作无法撤销。",
                "This permanently deletes the following index and all its documents. This action cannot be undone."
            ))
            Text(editor.selection.objectName)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .help(editor.selection.objectName)
            TextField(AppCopy.current.text("输入完整索引名称以确认", "Enter the full index name to confirm"), text: $editor.confirmation)
                .focused($confirmationIsFocused)
                .disabled(busy || editor.mustVerify || editor.isAbsent)
                .accessibilityLabel(AppCopy.current.text("确认删除的索引名称", "Index Name to Confirm Deletion"))
                .accessibilityIdentifier("deleteIndexConfirmation")
            ScrollView {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 64)
            WorkspaceDatabaseDataProgressBar(isActive: busy,
                accessibilityLabel: AppCopy.current.text("正在处理删除请求", "Processing Deletion Request"))
            HStack {
                Button(AppCopy.current.text("预览请求", "Preview Request")) { showsPreview = true }
                    .disabled(editor.prepared == nil || busy)
                    .popover(isPresented: $showsPreview) {
                        if let prepared = editor.prepared {
                            WorkspaceElasticsearchRequestPreviewView(requests: [prepared.request], dismiss: { showsPreview = false })
                        }
                    }
                Button(AppCopy.current.text("响应详情", "Response Details")) { showsResponse = true }
                    .disabled(editor.responseText.isEmpty || busy)
                    .popover(isPresented: $showsResponse) {
                        WorkspaceReadOnlyTextView(text: editor.responseText, usesMonospacedFont: true,
                            accessibilityLabel: AppCopy.current.text("删除索引响应", "Delete Index Response"), presentation: .automaticJSON)
                            .frame(width: 600, height: 300)
                    }
                Spacer()
                if busy {
                    Button(AppCopy.current.text("停止", "Stop")) { operation?.cancel() }
                        .disabled(!editor.isBusy)
                }
                Button(AppCopy.current.text("关闭", "Close"), role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                if editor.mustVerify {
                    Button(AppCopy.current.text("核实状态", "Verify Status"), action: verify)
                        .disabled(busy || model.connectionState != .connected)
                } else if !editor.isAbsent {
                    Button(AppCopy.current.text("删除索引", "Delete Index"), role: .destructive, action: requestDeletion)
                        .disabled(busy || !editor.canDelete || model.connectionState != .connected || model.elasticsearchHasPendingChanges())
                        .accessibilityIdentifier("deleteIndexSubmit")
                }
            }
        }
        .padding(20)
        .frame(width: 580)
        .interactiveDismissDisabled(busy)
        .task {
            await editor.prepare()
            confirmationIsFocused = true
        }
        .alert(AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"), isPresented: $showsUnlockConfirmation) {
            Button(AppCopy.current.text("允许此工作区进行更改", "Allow Changes for This Workspace"), role: .destructive) {
                model.safetyLock.disable()
                submit()
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(AppCopy.current.text("删除索引会永久移除全部文档。安全锁将保持停用，直到此工作区关闭。",
                "Deleting an index permanently removes all its documents. Safety Lock will remain disabled until this workspace closes."))
        }
        .onDisappear {
            operation?.cancel()
            refreshTask?.cancel()
        }
    }

    private var statusText: String {
        if model.elasticsearchHasPendingChanges() {
            return WorkspaceIndexDeletionError.pendingChanges.localizedDescription
        }
        return editor.message ?? AppCopy.current.text("名称必须完全一致，不接受通配符或多个索引。", "The name must match exactly. Wildcards and multiple indices are not accepted.")
    }

    private func requestDeletion() {
        guard !busy, editor.canDelete else { return }
        if model.safetyLock.isEnabled { showsUnlockConfirmation = true } else { submit() }
    }

    private func submit() {
        guard !busy, editor.canDelete else { return }
        operation = Task { @MainActor in
            defer { operation = nil }
            await editor.submit(execute: model.deleteElasticsearchIndex)
            if editor.didAttemptWrite { await reconcile() }
        }
    }

    private func verify() {
        guard !busy else { return }
        operation = Task { @MainActor in
            defer { operation = nil }
            await editor.verify(execute: model.executeElasticsearchRequest)
            if editor.isAbsent { await reconcile() }
        }
    }

    private func reconcile() async {
        // An uncertain canceled write still needs cache invalidation. Own this
        // refresh separately so it does not inherit the write's cancellation.
        refreshTask = Task { @MainActor in await model.didMutateElasticsearchMapping() }
        await refreshTask?.value
        refreshTask = nil
        guard editor.isAbsent, !didCloseObject, !model.elasticsearchHasPendingChanges() else { return }
        didCloseObject = true
        didDelete(editor.selection)
    }
}
