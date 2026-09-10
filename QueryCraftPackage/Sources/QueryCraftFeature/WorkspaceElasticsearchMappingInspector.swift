import SwiftUI

struct WorkspaceMappingInspectorContext: Equatable {
    let editor: WorkspaceElasticsearchMappingEditor
    let workspace: WorkspaceModel
    let identity: String
    @MainActor init(editor: WorkspaceElasticsearchMappingEditor, workspace: WorkspaceModel) {
        self.editor = editor; self.workspace = workspace
        identity = "mapping:\(editor.snapshot?.target.resource ?? ""):\(editor.selectedID?.uuidString ?? "")"
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.editor === rhs.editor && lhs.workspace === rhs.workspace && lhs.identity == rhs.identity }
}

struct WorkspaceElasticsearchMappingInspector: View {
    let context: WorkspaceMappingInspectorContext
    let searchText: String
    private var editor: WorkspaceElasticsearchMappingEditor { context.editor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Mapping").font(.headline)
                Spacer()
            }.padding(10)
            ScrollView {
                if let row = editor.selectedRow {
                    Form {
                        LabeledContent(AppCopy.current.text("目标", "Target"), value: editor.snapshot?.target.resource ?? "")
                        if row.isNew {
                            TextField(AppCopy.current.text("字段名", "Field Name"), text: binding(row, key: "name"))
                            Picker(AppCopy.current.text("类型", "Type"), selection: binding(row, key: "type")) {
                                ForEach(row.container == "fields" ? ["text", "keyword"] : WorkspaceMappingCodec.newTypes, id: \.self) { Text($0).tag($0) }
                            }
                            Picker(AppCopy.current.text("父节点", "Parent"), selection: Binding(
                                get: { editor.selectedRow?.parentPath ?? [] },
                                set: { path in
                                    guard var current = editor.selectedRow else { return }
                                    current.parentPath = path
                                    editor.update(current, workspace: context.workspace)
                                }
                            )) {
                                if row.container == "properties" { Text(AppCopy.current.text("根节点", "Root")).tag([String]()) }
                                ForEach(editor.rows.filter { candidate in
                                    candidate.id != row.id && !candidate.name.isEmpty && !candidate.path.starts(with: row.path)
                                        && (row.container == "fields" ? ["text", "keyword"].contains(candidate.type) : ["object", "nested"].contains(candidate.type))
                                }) { Text($0.displayPath).tag($0.path) }
                            }
                        } else {
                            LabeledContent(AppCopy.current.text("父节点", "Parent"), value: row.parentPath.isEmpty ? AppCopy.current.text("根节点", "Root") : row.parentPath.enumerated().filter { $0.offset % 2 == 1 }.map(\.element).joined(separator: "."))
                            LabeledContent(AppCopy.current.text("字段", "Field"), value: row.displayPath)
                            LabeledContent(AppCopy.current.text("类型", "Type"), value: row.type)
                        }
                        if row.hasConflict {
                            Text(AppCopy.current.text("各目标字段定义不一致，请在控制台核对后修改。", "Field definitions differ across targets. Review them in the console."))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(visibleParameters(row), id: \.self) { key in
                            parameter(row, key: key)
                        }
                        if row.container == "fields" {
                            Text(AppCopy.current.text("新增 multi-field 不会自动更新历史文档的索引值。", "Adding a multi-field does not populate indexed values for existing documents."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.formStyle(.grouped)
                        .disabled(editor.isLoading || editor.isCommitting || editor.isBlocked || editor.snapshot?.target.kind == .elasticsearchAlias)
                } else {
                    Text(AppCopy.current.text("选择字段查看参数。", "Select a field to inspect its parameters."))
                        .foregroundStyle(.secondary).padding()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func visibleParameters(_ row: WorkspaceMappingEditorRow) -> [String] {
        Set(row.editableParameters).union(row.parameters.keys.filter { $0 != "type" }).sorted().filter {
            searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText) || (row.parameters[$0] ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }
    @ViewBuilder private func parameter(_ row: WorkspaceMappingEditorRow, key: String) -> some View {
        if row.hasConflict || !row.editableParameters.contains(key) {
            LabeledContent(key, value: row.parameters[key] ?? AppCopy.current.text("服务器默认", "Server Default"))
        } else if ["analyzer", "normalizer", "format", "ignore_above"].contains(key) {
            TextField(key, text: binding(row, key: key), prompt: Text(AppCopy.current.text("服务器默认", "Server Default")))
        } else {
            Picker(key, selection: binding(row, key: key)) {
                if editor.originals.first(where: { $0.id == row.id })?.parameters[key] == nil {
                    Text(AppCopy.current.text("服务器默认", "Server Default")).tag("")
                }
                Text("true").tag("true")
                Text("false").tag("false")
            }
        }
    }
    private func binding(_ row: WorkspaceMappingEditorRow, key: String) -> Binding<String> {
        Binding(get: {
            guard let current = editor.rows.first(where: { $0.id == row.id }) else { return "" }
            return key == "name" ? current.name : key == "type" ? current.type : current.parameters[key] ?? ""
        }, set: { text in
            editor.requestEdit(workspace: context.workspace) {
                guard var current = editor.rows.first(where: { $0.id == row.id }) else { return }
                if key == "name" { current.name = text }
                else if key == "type" { current.type = text; current.parameters = [:] }
                else { current.parameters[key] = text.isEmpty ? nil : text }
                editor.update(current, workspace: context.workspace)
            }
        })
    }
}
