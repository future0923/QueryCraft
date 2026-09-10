import SwiftUI

struct WorkspaceIndexInspectorContext: Equatable {
    let selection: WorkspaceDatabaseObjectSelection
    let editor: WorkspaceElasticsearchIndexInspectorModel
    let aliasEditor: WorkspaceElasticsearchAliasEditor
    let workspace: WorkspaceModel
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selection == rhs.selection && lhs.editor === rhs.editor
            && lhs.aliasEditor === rhs.aliasEditor && lhs.workspace === rhs.workspace
    }
}

struct WorkspaceElasticsearchIndexInspectorView: View {
    let context: WorkspaceIndexInspectorContext
    let searchText: String
    private var editor: WorkspaceElasticsearchIndexInspectorModel { context.editor }
    private var unavailable: String {
        editor.snapshot == nil && editor.errorMessage == nil ? " " : AppCopy.current.text("未获取", "Unavailable")
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section(AppCopy.current.text("索引信息", "INDEX")) {
                    metadata(AppCopy.current.text("名称", "Name"), context.selection.objectName)
                    metadata(AppCopy.current.text("资源类型", "Resource Type"), resourceType)
                    metadata(AppCopy.current.text("健康状态", "Health"), editor.snapshot?.health ?? unavailable)
                    metadata(AppCopy.current.text("文档数", "Documents"), editor.snapshot?.documentCount.map { $0.formatted(.number.grouping(.automatic)) } ?? unavailable)
                    metadata(AppCopy.current.text("主分片数", "Primary Shards"), value("index.number_of_shards"))
                }
                if [.elasticsearchIndex, .elasticsearchAlias].contains(context.selection.kind),
                   !context.selection.objectName.hasPrefix(".ds-") {
                    WorkspaceElasticsearchAliasManagementSection(
                        selection: context.selection,
                        editor: context.aliasEditor,
                        workspace: context.workspace
                    )
                }
                Section {
                    setting(AppCopy.current.text("副本数", "Replicas"), key: WorkspaceIndexSettingsWorker.replicasKey, isReplicas: true)
                    setting(AppCopy.current.text("刷新间隔", "Refresh Interval"), key: WorkspaceIndexSettingsWorker.intervalKey, isReplicas: false)
                    if editor.isEditing {
                        Text(AppCopy.current.text("使用顶部工具栏放弃、预览或提交。-1 表示停用自动刷新。", "Discard, preview, or commit from the top toolbar. -1 disables automatic refresh."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if context.selection.kind != .elasticsearchIndex || context.selection.objectName.hasPrefix(".ds-") {
                        Text(AppCopy.current.text("此处仅汇总目标索引设置。请打开实际普通索引进行修改。", "This is a summary of target index settings. Open an ordinary index to edit its settings."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(AppCopy.current.text("索引设置", "SETTINGS"))
                        Spacer()
                        if context.selection.kind == .elasticsearchIndex && !context.selection.objectName.hasPrefix(".ds-") {
                            WorkspaceInlineIconButton(systemImageName: editor.isEditing ? "checkmark" : "pencil",
                                title: AppCopy.current.text(editor.isEditing ? "结束设置编辑" : "编辑索引设置", editor.isEditing ? "Finish Editing Settings" : "Edit Index Settings"),
                                isEnabled: editor.canEdit && (!editor.isEditing || !editor.hasChanges)) {
                                    if editor.isEditing { editor.discard() }
                                    else { editor.requestEdit(workspace: context.workspace) }
                                }
                        }
                    }
                }
                Section(AppCopy.current.text("大小", "SIZE")) {
                    metadata(AppCopy.current.text("存储大小（含副本）", "Storage (Including Replicas)"), editor.snapshot?.storeBytes.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? unavailable)
                }
                Section(AppCopy.current.text("访问限制", "ACCESS BLOCKS")) {
                    metadata(AppCopy.current.text("禁止读取", "Block Reads"), value("index.blocks.read"), key: "index.blocks.read")
                    metadata(AppCopy.current.text("禁止写入", "Block Writes"), value("index.blocks.write"), key: "index.blocks.write")
                    metadata(AppCopy.current.text("只读", "Read Only"), value("index.blocks.read_only"), key: "index.blocks.read_only")
                    metadata(AppCopy.current.text("只读（允许删除索引）", "Read Only (Allow Index Deletion)"), value("index.blocks.read_only_allow_delete"), key: "index.blocks.read_only_allow_delete")
                }
                if context.selection.kind == .elasticsearchDataStream, let snapshot = editor.snapshot {
                    Section(AppCopy.current.text("实际索引", "ACTUAL INDICES")) {
                        ForEach(snapshot.indices, id: \.name) { index in
                            metadata(index.name, AppCopy.current.text("主分片", "Primary Shards") + ": " + (index.effective("index.number_of_shards") ?? unavailable))
                        }
                    }
                }
                if let message = editor.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if let message = context.aliasEditor.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                ForEach(editor.snapshot?.warnings ?? [], id: \.self) { warning in
                    Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .listRowSeparator(.hidden)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            WorkspaceDatabaseDataProgressBar(isActive: editor.isLoading || editor.isCommitting
                || context.aliasEditor.isLoading || context.aliasEditor.isCommitting)
            Divider()
            WorkspaceIndexSettingsActionsView(editor: editor, workspace: context.workspace)
                .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("elasticsearchIndexInspector")
    }

    private var resourceType: String {
        switch context.selection.kind {
        case .elasticsearchAlias: "Alias"
        case .elasticsearchDataStream: "Data Stream"
        default: "Index"
        }
    }
    private func value(_ key: String) -> String {
        guard let snapshot = editor.snapshot, !snapshot.indices.isEmpty else { return unavailable }
        let values = Set(snapshot.indices.map { index in
            if let explicit = index.settings[key] { return explicit }
            return AppCopy.current.text("服务器默认", "Server Default") + (index.defaults[key].map { " (\($0))" } ?? "")
        })
        return values.count == 1 ? values.first! : AppCopy.current.text("各索引不同", "Varies Across Indices")
    }
    private func matches(_ label: String, _ value: String) -> Bool {
        searchText.isEmpty || label.localizedCaseInsensitiveContains(searchText) || value.localizedCaseInsensitiveContains(searchText)
    }
    @ViewBuilder private func metadata(_ label: String, _ value: String, key: String? = nil) -> some View {
        if matches(label + " " + (key ?? ""), value) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.subheadline).lineLimit(1).help(key ?? label)
                WorkspaceInspectorMetadataValue(value: value)
            }
            .listRowSeparator(.hidden)
        }
    }
    @ViewBuilder private func setting(_ label: String, key: String, isReplicas: Bool) -> some View {
        if matches(label + " " + key, value(key)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.subheadline).lineLimit(1).help(key)
                if editor.isEditing {
                    TextField(label, text: Binding(get: { isReplicas ? editor.replicas : editor.interval }, set: { text in
                        editor.update(replicas: isReplicas ? text : editor.replicas,
                            interval: isReplicas ? editor.interval : text, workspace: context.workspace)
                    }))
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .disabled(editor.isCommitting || editor.isBlocked)
                    .accessibilityIdentifier(isReplicas ? "indexReplicasEditor" : "indexRefreshIntervalEditor")
                    Text(AppCopy.current.text("原值：", "Original: ") + value(key))
                        .font(.caption).foregroundStyle((isReplicas ? editor.replicas : editor.interval) != editor.snapshot?.editableIndex?.effective(key)
                            ? Color.accentColor : Color.secondary)
                } else { WorkspaceInspectorMetadataValue(value: value(key)) }
            }
            .listRowSeparator(.hidden)
        }
    }
}
