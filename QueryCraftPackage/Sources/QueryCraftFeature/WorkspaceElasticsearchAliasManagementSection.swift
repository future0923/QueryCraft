import SwiftUI

struct WorkspaceElasticsearchAliasManagementSection: View {
    let selection: WorkspaceDatabaseObjectSelection
    let editor: WorkspaceElasticsearchAliasEditor
    let workspace: WorkspaceModel

    var body: some View {
        Section {
            if editor.rows.isEmpty, !editor.showsAddBinding {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(editor.rows) { row in
                bindingRow(row)
            }
            if editor.showsAddBinding {
                addBindingRow
            }
            if editor.hasChanges {
                Text(AppCopy.current.text(
                    "使用顶部工具栏放弃、预览请求或提交。",
                    "Discard, preview the request, or commit from the top toolbar."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(sectionTitle)
                Spacer()
                WorkspaceInlineIconButton(
                    systemImageName: "plus",
                    title: addTitle,
                    isEnabled: editor.canEdit && !editor.showsAddBinding
                ) {
                    editor.beginAdding(workspace: workspace)
                }
            }
        }
    }

    private func bindingRow(_ row: WorkspaceElasticsearchAliasEditorRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(row.isModified ? Color.accentColor : Color.clear)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(displayName(row.binding))
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(row.isRemoved)
                    .help(displayName(row.binding))
                Spacer(minLength: 8)
                if selection.kind == .elasticsearchAlias {
                    Toggle(AppCopy.current.text("写索引", "Write Index"), isOn: Binding(
                        get: { row.binding.isWriteIndex == true },
                        set: { editor.setWriteIndex(rowID: row.id, isWriteIndex: $0, workspace: workspace) }
                    ))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(row.isRemoved || !editor.canEdit)
                    .help(AppCopy.current.text(
                        "将此目标设置为 Alias 的写索引",
                        "Use this target as the alias write index"
                    ))
                }
                WorkspaceInlineIconButton(
                    systemImageName: row.isRemoved ? "arrow.uturn.backward" : "minus",
                    title: row.isRemoved
                        ? AppCopy.current.text("撤销移除", "Undo Removal")
                        : AppCopy.current.text("移除绑定", "Remove Binding"),
                    isEnabled: editor.canEdit
                ) {
                    editor.toggleRemoval(rowID: row.id, workspace: workspace)
                }
            }
            if selection.kind == .elasticsearchAlias,
               row.binding.isWriteIndex == nil, !row.isRemoved {
                Text(AppCopy.current.text(
                    "服务器未显式设置写索引" + (activeRowCount == 1 ? "；单目标时可自动写入" : ""),
                    "No explicit write index" + (activeRowCount == 1 ? "; a single target can receive writes automatically" : "")
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 13)
            }
        }
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .contain)
    }

    private var addBindingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selection.kind == .elasticsearchIndex {
                TextField(AppCopy.current.text("Alias 名称", "Alias Name"), text: Binding(
                    get: { editor.newBindingName },
                    set: { editor.newBindingName = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("elasticsearchNewAliasName")
            } else {
                Picker(AppCopy.current.text("目标索引", "Target Index"), selection: Binding(
                    get: { editor.newBindingName },
                    set: { editor.newBindingName = $0 }
                )) {
                    Text(AppCopy.current.text("选择索引", "Choose Index"))
                        .tag("")
                    ForEach(availableTargetIndices, id: \.self) { index in
                        Text(index).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(AppCopy.current.text("设为写索引", "Set as Write Index"), isOn: Binding(
                    get: { editor.newBindingIsWriteIndex },
                    set: { editor.newBindingIsWriteIndex = $0 }
                ))
                .toggleStyle(.checkbox)
            }
            HStack(spacing: 8) {
                Button(AppCopy.current.text("新增", "Add")) {
                    editor.addBinding(workspace: workspace)
                }
                .disabled(editor.newBindingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
                Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {
                    editor.cancelAdding()
                }
                .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 3)
        .listRowSeparator(.hidden)
    }

    private var availableTargetIndices: [String] {
        let active = Set(editor.rows.filter { !$0.isRemoved }.map(\.binding.indexName))
        return workspace.elasticsearchOrdinaryIndexNames.filter { !active.contains($0) }
    }

    private var activeRowCount: Int { editor.rows.filter { !$0.isRemoved }.count }
    private var sectionTitle: String {
        selection.kind == .elasticsearchAlias
            ? AppCopy.current.text("实际索引", "TARGET INDICES")
            : "ALIASES"
    }
    private var addTitle: String {
        selection.kind == .elasticsearchAlias
            ? AppCopy.current.text("添加目标索引", "Add Target Index")
            : AppCopy.current.text("新增 Alias", "Add Alias")
    }
    private var emptyMessage: String {
        selection.kind == .elasticsearchAlias
            ? AppCopy.current.text("此 Alias 没有实际索引。", "This alias has no target indices.")
            : AppCopy.current.text("此索引没有 Alias。", "This index has no aliases.")
    }
    private func displayName(_ binding: WorkspaceElasticsearchAliasBinding) -> String {
        selection.kind == .elasticsearchAlias ? binding.indexName : binding.aliasName
    }
}
