import SwiftUI

struct WorkspaceElasticsearchIndexTemplateManagerSheet: View {
    let model: WorkspaceModel
    let dismiss: @MainActor () -> Void

    @State private var editor = WorkspaceElasticsearchIndexTemplateEditor()
    @State private var operation: Task<Void, Never>?
    @State private var formatTask: Task<Void, Never>?
    @State private var preview: WorkspacePreparedElasticsearchIndexTemplateMutation?
    @State private var pendingMutation: WorkspacePreparedElasticsearchIndexTemplateMutation?
    @State private var pendingNavigation: PendingNavigation?
    @State private var showsUnlockConfirmation = false
    @State private var showsDeleteConfirmation = false
    @State private var showsDiscardConfirmation = false
    @State private var showsResponse = false
    @State private var showsSimulation = false
    @FocusState private var nameIsFocused: Bool

    private enum PendingNavigation {
        case select(String)
        case create
        case close
    }

    private var busy: Bool { operation != nil || editor.isBusy }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                templateList
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 340)
                editorContent
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            }
            WorkspaceDatabaseDataProgressBar(
                isActive: busy || formatTask != nil,
                accessibilityLabel: AppCopy.current.text(
                    "正在处理索引模板",
                    "Processing Index Templates"
                )
            )
            Divider()
            bottomBar
        }
        .frame(minWidth: 780, idealWidth: 920, minHeight: 540, idealHeight: 640)
        .interactiveDismissDisabled(editor.hasChanges || busy)
        .task {
            await editor.load(execute: model.executeElasticsearchRequest)
        }
        .task(id: editor.input) {
            await editor.validate()
        }
        .alert(
            AppCopy.current.text("放弃模板更改？", "Discard Template Changes?"),
            isPresented: $showsDiscardConfirmation
        ) {
            Button(AppCopy.current.text("放弃并继续", "Discard and Continue"), role: .destructive) {
                performPendingNavigation()
            }
            Button(AppCopy.current.text("继续编辑", "Keep Editing"), role: .cancel) {
                pendingNavigation = nil
            }
        } message: {
            Text(AppCopy.current.text(
                "当前模板有未保存的更改。继续会永久放弃这些输入。",
                "The current template has unsaved changes. Continuing permanently discards that input."
            ))
        }
        .alert(
            AppCopy.current.text("删除索引模板？", "Delete Index Template?"),
            isPresented: $showsDeleteConfirmation
        ) {
            Button(AppCopy.current.text("删除", "Delete"), role: .destructive) {
                authorizePendingMutation()
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {
                pendingMutation = nil
            }
        } message: {
            Text(AppCopy.current.text(
                "将永久删除索引模板“\(pendingMutation?.input.name ?? "")”。现有索引不会被删除，但以后创建的索引和 Data Stream 可能不再获得该模板。",
                "This permanently deletes the “\(pendingMutation?.input.name ?? "")” index template. Existing indices remain, but future indices and Data Streams may no longer receive it."
            ))
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $showsUnlockConfirmation
        ) {
            Button(
                AppCopy.current.text("允许此工作区进行更改", "Allow Changes for This Workspace"),
                role: .destructive
            ) {
                model.safetyLock.disable()
                submitPendingMutation()
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {
                pendingMutation = nil
            }
        } message: {
            Text(AppCopy.current.text(
                "保存或删除索引模板会更改集群结构。安全锁将保持停用，直到此工作区关闭。",
                "Saving or deleting an index template changes the cluster structure. Safety Lock remains disabled until this workspace closes."
            ))
        }
        .onDisappear {
            operation?.cancel()
            formatTask?.cancel()
        }
    }

    private var templateList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(AppCopy.current.text("索引模板", "Index Templates"))
                    .font(.headline)
                Spacer(minLength: 4)
                WorkspaceInlineIconButton(
                    systemImageName: "arrow.clockwise",
                    title: AppCopy.current.text("刷新模板", "Refresh Templates"),
                    isEnabled: !busy && !editor.hasChanges,
                    action: refresh
                )
                WorkspaceInlineIconButton(
                    systemImageName: "plus",
                    title: AppCopy.current.text("新建索引模板", "New Index Template"),
                    isEnabled: !busy,
                    action: requestCreation
                )
            }
            .padding(8)

            WorkspaceGridSearchField(
                text: $editor.searchText,
                placeholder: AppCopy.current.text("搜索模板", "Search templates"),
                focusRequest: 0,
                submit: {},
                cancel: { editor.searchText = "" },
                accessibilityIdentifier: "elasticsearchIndexTemplateSearch"
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            Divider()
            List(selection: templateSelection) {
                ForEach(editor.visibleTemplates) { template in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !template.indexPatterns.isEmpty {
                            Text(template.indexPatterns.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .tag(template.name)
                    .help(template.name)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .overlay {
                if !editor.isLoading && editor.visibleTemplates.isEmpty {
                    ContentUnavailableView(
                        editor.searchText.isEmpty
                            ? AppCopy.current.text("没有索引模板", "No Index Templates")
                            : AppCopy.current.text("没有匹配的模板", "No Matching Templates"),
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        if showsSimulation {
            WorkspaceElasticsearchTemplateSimulationView(execute: model.executeElasticsearchRequest)
        } else if editor.hasSelection {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if editor.isCreating {
                        TextField(
                            AppCopy.current.text("模板名称", "Template Name"),
                            text: $editor.input.name
                        )
                        .focused($nameIsFocused)
                        .accessibilityIdentifier("elasticsearchIndexTemplateName")
                    } else {
                        Text(editor.input.name)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button(AppCopy.current.text("格式化", "Format"), action: formatSource)
                        .disabled(busy || formatTask != nil)
                    WorkspaceInlineIconButton(
                        systemImageName: "trash",
                        title: AppCopy.current.text("删除索引模板", "Delete Index Template"),
                        isEnabled: editor.canDelete,
                        action: requestDeletion
                    )
                }
                .padding(10)
                Divider()
                WorkspaceJSONTextView(
                    text: $editor.input.source,
                    isEditable: !busy,
                    accessibilityLabel: AppCopy.current.text(
                        "索引模板 JSON",
                        "Index Template JSON"
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView {
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(
                            editor.validationMessage == nil
                                ? Color(nsColor: .secondaryLabelColor)
                                : Color(nsColor: .systemRed)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 54)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        } else {
            ContentUnavailableView(
                AppCopy.current.text("选择索引模板", "Select an Index Template"),
                systemImage: "doc.text.magnifyingglass",
                description: Text(AppCopy.current.text(
                    "选择一个模板查看完整 JSON，或新建模板。",
                    "Select a template to inspect its full JSON, or create a new one."
                ))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button(showsSimulation
                ? AppCopy.current.text("返回模板", "Back to Template")
                : AppCopy.current.text("匹配预览", "Match Preview")) {
                showsSimulation.toggle()
            }
            .disabled(busy)
            .accessibilityIdentifier("templateMatchPreview")
            if !showsSimulation {
                Button(AppCopy.current.text("响应详情", "Response Details")) {
                    showsResponse = true
                }
                .disabled(editor.responseText.isEmpty || busy)
                .popover(isPresented: $showsResponse) {
                    WorkspaceReadOnlyTextView(
                        text: editor.responseText,
                        usesMonospacedFont: true,
                        accessibilityLabel: AppCopy.current.text(
                            "索引模板响应",
                            "Index Template Response"
                        ),
                        presentation: .automaticJSON
                    )
                    .frame(width: 600, height: 340)
                }
                Button(AppCopy.current.text("预览请求", "Preview Request")) {
                    preview = editor.preparedSave
                }
                .disabled(editor.preparedSave == nil || busy)
                .popover(isPresented: Binding(
                    get: { preview != nil },
                    set: { if !$0 { preview = nil } }
                )) {
                    if let preview {
                        WorkspaceElasticsearchRequestPreviewView(
                            requests: [preview.request],
                            dismiss: { self.preview = nil }
                        )
                    }
                }
                Button(AppCopy.current.text("放弃", "Discard"), role: .destructive) {
                    editor.discard()
                }
                .disabled(!editor.hasChanges || busy)
            }
            Spacer()
            if operation != nil {
                Button(AppCopy.current.text("停止", "Stop")) {
                    operation?.cancel()
                }
            }
            Button(AppCopy.current.text("关闭", "Close"), role: .cancel) {
                requestClose()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(busy)
            if !showsSimulation {
                Button(AppCopy.current.text("保存", "Save"), action: requestSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editor.canSave || busy)
                    .accessibilityIdentifier("saveElasticsearchIndexTemplate")
            }
        }
        .padding(10)
    }

    private var templateSelection: Binding<String?> {
        Binding(
            get: { editor.selectedName },
            set: { name in
                guard let name, name != editor.selectedName else { return }
                requestNavigation(.select(name))
            }
        )
    }

    private var statusText: String {
        if let validation = editor.validationMessage { return validation }
        if let message = editor.message { return message }
        if editor.isCreating {
            return AppCopy.current.text(
                "填写名称和完整模板 JSON。index_patterns 决定模板匹配范围。",
                "Enter a name and the complete template JSON. index_patterns controls matching."
            )
        }
        if let template = editor.baseline {
            let priority = template.priority.map(String.init) ?? AppCopy.current.text("服务器默认", "Server Default")
            return AppCopy.current.text(
                "匹配：\(template.indexPatterns.joined(separator: ", ")) · 优先级：\(priority)" + (template.isDataStream ? " · Data Stream" : ""),
                "Patterns: \(template.indexPatterns.joined(separator: ", ")) · Priority: \(priority)" + (template.isDataStream ? " · Data Stream" : "")
            )
        }
        return ""
    }

    private func requestCreation() {
        requestNavigation(.create)
    }

    private func requestClose() {
        requestNavigation(.close)
    }

    private func requestNavigation(_ navigation: PendingNavigation) {
        guard !busy else { return }
        if editor.hasChanges {
            pendingNavigation = navigation
            showsDiscardConfirmation = true
        } else {
            perform(navigation)
        }
    }

    private func performPendingNavigation() {
        guard let navigation = pendingNavigation else { return }
        pendingNavigation = nil
        editor.discard()
        perform(navigation)
    }

    private func perform(_ navigation: PendingNavigation) {
        showsSimulation = false
        switch navigation {
        case .select(let name):
            guard let template = editor.templates.first(where: { $0.name == name }) else { return }
            editor.select(template)
        case .create:
            editor.beginCreating()
            nameIsFocused = true
        case .close:
            dismiss()
        }
    }

    private func refresh() {
        guard operation == nil else { return }
        operation = Task { @MainActor in
            defer { operation = nil }
            await editor.load(execute: model.executeElasticsearchRequest)
        }
    }

    private func formatSource() {
        guard formatTask == nil else { return }
        formatTask = Task { @MainActor in
            defer { formatTask = nil }
            await editor.formatSource()
        }
    }

    private func requestSave() {
        guard let prepared = editor.preparedSave, !busy else { return }
        pendingMutation = prepared
        authorizePendingMutation()
    }

    private func requestDeletion() {
        guard let prepared = editor.preparedDeletion, !busy else { return }
        pendingMutation = prepared
        showsDeleteConfirmation = true
    }

    private func authorizePendingMutation() {
        guard pendingMutation != nil else { return }
        if model.safetyLock.isEnabled {
            showsUnlockConfirmation = true
        } else {
            submitPendingMutation()
        }
    }

    private func submitPendingMutation() {
        guard let prepared = pendingMutation, operation == nil else { return }
        pendingMutation = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            await editor.submit(
                prepared,
                commit: model.commitElasticsearchIndexTemplate,
                execute: model.executeElasticsearchRequest
            )
            if editor.lastSubmissionMayHaveReachedServer {
                await model.didMutateElasticsearchMapping()
            }
        }
    }
}
