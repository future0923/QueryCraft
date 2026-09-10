import SwiftUI

struct WorkspaceElasticsearchIndexCreationSheet: View {
    let model: WorkspaceModel
    let openIndex: @MainActor (String) -> Void
    let dismiss: @MainActor () -> Void

    @State private var editor = WorkspaceElasticsearchIndexCreationEditor()
    @State private var operation: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    @State private var preview: WorkspacePreparedIndexCreation?
    @State private var pendingCreation: WorkspacePreparedIndexCreation?
    @State private var showsUnlockConfirmation = false
    @State private var showsResponse = false
    @State private var formatTask: Task<Void, Never>?
    @FocusState private var nameIsFocused: Bool

    private var busy: Bool { operation != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppCopy.current.text("创建索引", "Create Index"))
                .font(.title2.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(AppCopy.current.text("索引名称", "Index Name"))
                    TextField("", text: $editor.input.name)
                        .focused($nameIsFocused)
                        .accessibilityLabel(AppCopy.current.text("索引名称", "Index Name"))
                        .accessibilityIdentifier("createIndexName")
                }
                GridRow {
                    Text(AppCopy.current.text("主分片数", "Primary Shards"))
                    TextField(AppCopy.current.text("服务器默认", "Server Default"), text: $editor.input.shards)
                        .accessibilityLabel(AppCopy.current.text("主分片数", "Primary Shards"))
                }
                GridRow {
                    Text(AppCopy.current.text("副本数", "Replicas"))
                    TextField(AppCopy.current.text("服务器默认", "Server Default"), text: $editor.input.replicas)
                        .accessibilityLabel(AppCopy.current.text("副本数", "Replicas"))
                }
            }
            .disabled(!editor.canEdit || busy)

            HStack {
                Text(AppCopy.current.text("初始 Mapping", "Initial Mapping"))
                Spacer()
                Button(AppCopy.current.text("格式化", "Format"), action: formatMapping)
                    .disabled(!editor.canEdit || busy || formatTask != nil)
            }
            WorkspaceJSONTextView(
                text: $editor.input.mapping,
                isEditable: editor.canEdit && !busy,
                accessibilityLabel: AppCopy.current.text("初始 Mapping JSON", "Initial Mapping JSON")
            )
            .border(Color(nsColor: .separatorColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Status and progress keep their space, including during validation and refresh.
            ScrollView {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 64)

            WorkspaceDatabaseDataProgressBar(
                isActive: busy,
                accessibilityLabel: AppCopy.current.text("正在处理索引请求", "Processing Index Request")
            )
            HStack {
                Button(AppCopy.current.text("预览请求", "Preview Request")) {
                    preview = editor.currentPrepared
                }
                .disabled(editor.currentPrepared == nil || busy)
                .popover(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                    if let preview {
                        WorkspaceElasticsearchRequestPreviewView(requests: [preview.request], dismiss: { self.preview = nil })
                    }
                }
                Button(AppCopy.current.text("响应详情", "Response Details")) { showsResponse = true }
                    .disabled(editor.responseText.isEmpty || busy)
                    .popover(isPresented: $showsResponse) {
                        WorkspaceReadOnlyTextView(
                            text: editor.responseText,
                            usesMonospacedFont: true,
                            accessibilityLabel: AppCopy.current.text("创建索引响应", "Create Index Response"),
                            presentation: .automaticJSON
                        )
                        .frame(width: 600, height: 340)
                    }
                Spacer()
                if busy {
                    Button(AppCopy.current.text("停止", "Stop")) { operation?.cancel() }
                        .disabled(!editor.isBusy)
                }
                Button(AppCopy.current.text("关闭", "Close"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                if editor.indexExists {
                    Button(editor.wasCreated
                        ? AppCopy.current.text("打开索引", "Open Index")
                        : AppCopy.current.text("打开核对", "Open to Verify")) {
                        if let name = editor.lastAttempt?.input.name { openIndex(name) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || model.connectionState != .connected)
                } else if editor.mustVerify {
                    Button(AppCopy.current.text("核实状态", "Verify Status"), action: verify)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || model.connectionState != .connected)
                } else {
                    Button(AppCopy.current.text("创建", "Create"), action: requestCreation)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!editor.canSubmit || busy || model.connectionState != .connected)
                        .accessibilityIdentifier("createIndexSubmit")
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 570)
        .interactiveDismissDisabled(busy)
        .task { nameIsFocused = true }
        .task(id: editor.input) { await editor.validate() }
        .onChange(of: editor.input) { _, _ in
            preview = nil
            editor.clearPreviousFeedback()
        }
        .alert(AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"), isPresented: $showsUnlockConfirmation) {
            Button(AppCopy.current.text("允许此工作区进行更改", "Allow Changes for This Workspace"), role: .destructive) {
                model.safetyLock.disable()
                submit()
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) { pendingCreation = nil }
        } message: {
            Text(AppCopy.current.text(
                "创建索引会更改集群结构。安全锁将保持停用，直到此工作区关闭。",
                "Creating an index changes the cluster structure. Safety Lock will remain disabled until this workspace closes."
            ))
        }
        .onDisappear {
            operation?.cancel()
            refreshTask?.cancel()
            formatTask?.cancel()
        }
    }

    private var statusText: String {
        if let message = editor.message { return message }
        if !editor.input.name.isEmpty, let message = editor.validationMessage { return message }
        return AppCopy.current.text(
            "分片和副本留空时使用服务器或索引模板默认值。Mapping 留为 {} 即不指定字段。",
            "Leave shards and replicas empty to use server or index-template defaults. Keep Mapping as {} to leave fields unspecified."
        )
    }

    private func requestCreation() {
        guard !busy, editor.canSubmit, let snapshot = editor.currentPrepared else { return }
        pendingCreation = snapshot
        if model.safetyLock.isEnabled { showsUnlockConfirmation = true } else { submit() }
    }

    private func submit() {
        guard !busy, let snapshot = pendingCreation else { return }
        pendingCreation = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            await editor.submit(snapshot, execute: model.executeElasticsearchRequest)
            await refreshAfterAttempt()
        }
    }

    private func verify() {
        guard !busy else { return }
        operation = Task { @MainActor in
            defer { operation = nil }
            await editor.verify(execute: model.executeElasticsearchRequest)
            if editor.indexExists { await refreshAfterAttempt() }
        }
    }

    private func refreshAfterAttempt() async {
        // Reconciliation must also run after an uncertain, canceled write. This
        // separately owned task intentionally does not inherit that cancellation.
        refreshTask = Task { @MainActor in await model.didMutateElasticsearchMapping() }
        await refreshTask?.value
        refreshTask = nil
    }

    private func formatMapping() {
        guard formatTask == nil else { return }
        let source = editor.input.mapping
        formatTask = Task { @MainActor in
            defer { formatTask = nil }
            guard let formatted = try? await WorkspaceJSONPresentationWorker().format(source, automatic: false),
                  !Task.isCancelled, editor.canEdit, !busy, editor.input.mapping == source else { return }
            editor.input.mapping = formatted
        }
    }
}
