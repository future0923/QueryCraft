import SwiftUI
import QueryCraftMobileCore

struct MobileStructureView: View {
    @Bindable var model: MobileBrowserModel
    var controller: MobileSchemaController? = nil
    var body: some View {
        if let controller, let object = model.selectedObject {
            MobileSchemaContent(controller: controller, draft: controller.draft(for: object))
                .id(object.id)
        } else {
            // Standalone model previews keep the same stable readonly container.
            List(model.columns ?? []) { column in LabeledContent(column.name, value: column.type) }
        }
    }
}

struct MobileSchemaContent: View {
    @Bindable var controller: MobileSchemaController
    @Bindable var draft: MobileSchemaDraft
    @State private var edit: MobileSchemaEditSelection?
    @State private var pending = false
    @State private var viewport = MobileGridViewport()
    @State private var restorationID = UUID()
    @State private var listPosition: String?
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if draft.presentation == .table {
                    MobileDataGrid(data: gridData, revision: draft.revision.uuidString, widthKey: draft.object.id + ".schema." + draft.section.rawValue,
                        viewport: viewport, restorationID: restorationID, viewportOwner: draft.id,
                        cellAccessibilityHint: "轻点编辑结构项目", onInspect: { row, _ in
                            let ids = itemIDs; guard ids.indices.contains(row) else { return }; open(ids[row])
                        })
                } else {
                    ScrollViewReader { proxy in
                        List {
                            if draft.section == .columns {
                                ForEach(draft.state.columns, id: \.schemaPresentationID) { item in
                                    row(id: item.id, presentationID: item.schemaPresentationID, name: item.definition.name, detail: item.definition.type,
                                        subtitle: item.definition.comment, deleted: item.isDeleted, changed: item.isModified,
                                        extra: (draft.state.isPrimaryKey(columnID: item.id) ? "主键 · " : "") + (item.definition.isNullable ? "NULL" : "NOT NULL"))
                                }
                            } else {
                                ForEach(draft.state.indexes, id: \.schemaPresentationID) { item in
                                    row(id: item.id, presentationID: item.schemaPresentationID, name: item.definition.kind == .primary ? "PRIMARY" : item.definition.name,
                                        detail: item.definition.kind.rawValue.uppercased(), subtitle: item.definition.columns.map(\.name).joined(separator: ", "),
                                        deleted: item.isDeleted, changed: item.isModified, extra: item.definition.method)
                                }
                            }
                        }.listStyle(.insetGrouped)
                            .onAppear { if let listPosition { proxy.scrollTo(listPosition, anchor: .center) } }
                    }
                }
            }.overlay {
                if draft.snapshot != nil && itemIDs.isEmpty && !controller.isLoading {
                    ContentUnavailableView(draft.section == .columns ? "没有字段" : "没有索引", systemImage: "tablecells")
                }
            }
            HStack(spacing: 12) {
                Menu {
                    Picker("结构", selection: $draft.section) { ForEach(MobileSchemaDraft.Section.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("显示方式", selection: $draft.presentation) { ForEach(MobileSchemaDraft.Presentation.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                } label: { Label(draft.section.rawValue, systemImage: draft.presentation == .table ? "tablecells" : "list.bullet") }.labelStyle(.titleAndIcon)
                ProgressView().controlSize(.small).opacity(controller.isLoading ? 1 : 0)
                Text(draft.message ?? "\(itemIDs.count) 个\(draft.section.rawValue)").font(.caption)
                    .foregroundStyle(draft.isError ? Color.red : .secondary).lineLimit(2)
                Spacer(minLength: 0)
                if draft.hasChanges || draft.requiresReload || draft.needsVerification {
                    Button("待提交结构改动", systemImage: "square.and.pencil") { pending = true }.labelStyle(.iconOnly)
                }
                Button("新增" + draft.section.rawValue, systemImage: "plus") {
                    guard controller.canEdit(draft) else { return }; let id = draft.add(); open(id, added: true)
                }.labelStyle(.iconOnly).disabled(!controller.canEdit(draft))
            }.padding(.horizontal, 16).frame(height: 44)
        }
        .onAppear { viewport.activeOwner = draft.id }
        .onChange(of: draft.epoch, initial: true) { _, _ in
            #if DEBUG
            if draft.snapshot != nil, ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_SCHEMA_EDITOR"] == "1", edit == nil {
                let id = draft.section == .columns ? draft.state.columns.first { $0.definition.name != "id" }?.id : draft.state.indexes.first { $0.definition.kind != .primary }?.id
                if let id { open(id) }
            }
            #endif
        }
        .onChange(of: draft.section) { _, _ in restorationID = UUID(); draft.selectedID = nil; listPosition = nil }
        .onChange(of: draft.presentation) { _, _ in restorationID = UUID() }
        .sheet(item: $edit) { selection in
            if selection.section == .columns { MobileSchemaColumnEditor(controller: controller, draft: draft, selection: selection) { edit = nil } }
            else { MobileSchemaIndexEditor(controller: controller, draft: draft, selection: selection) { edit = nil } }
        }
        .sheet(isPresented: $pending) { MobileSchemaPendingView(controller: controller, draft: draft) { pending = false } }
    }
    private var itemIDs: [UUID] { draft.section == .columns ? draft.state.columns.map(\.id) : draft.state.indexes.map(\.id) }
    private func open(_ id: UUID, added: Bool = false) {
        guard controller.canEdit(draft) else { return }
        let deleted = draft.section == .columns ? draft.state.columns.first { $0.id == id }?.isDeleted : draft.state.indexes.first { $0.id == id }?.isDeleted
        guard deleted == false else { draft.restore(id); return }
        draft.selectedID = id
        listPosition = draft.section == .columns ? draft.state.columns.first { $0.id == id }?.schemaPresentationID : draft.state.indexes.first { $0.id == id }?.schemaPresentationID
        edit = .init(itemID: id, epoch: draft.epoch, section: draft.section, added: added)
    }
    private func row(id: UUID, presentationID: String, name: String, detail: String, subtitle: String, deleted: Bool, changed: Bool, extra: String) -> some View {
        Button { open(id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(name.isEmpty ? "未命名" : name).font(.body.weight(.medium)).strikethrough(deleted); Spacer(); Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary) }
                if !extra.isEmpty { Text(extra).font(.caption).foregroundStyle(.secondary) }
                if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            }.foregroundStyle(deleted ? Color.red : changed ? Color.orange : Color.primary).padding(.vertical, 4)
        }.id(presentationID).listRowBackground(draft.selectedID == id ? Color.accentColor.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground))
        .contextMenu {
            Button(deleted ? "恢复" : "编辑") { if deleted { draft.restore(id) } else { open(id) } }.disabled(!controller.canEdit(draft))
            if !deleted { Button("暂存删除", role: .destructive) { draft.delete(id) }.disabled(!controller.canEdit(draft)) }
        }
    }
    var gridData: MobileGridData {
        var result: MobileGridData
        let changes: [Bool], deletions: [Bool]
        if draft.section == .columns {
            result = .init(columns: ["名称", "类型", "主键", "允许 NULL", "默认值", "附加", "注释"], rows: draft.state.columns.map { item in
                let d = item.definition
                return [d.name, d.type, draft.state.isPrimaryKey(columnID: item.id) ? "是" : "", d.isNullable ? "是" : "否", d.defaultMode == .null ? "NULL" : d.defaultMode == .none ? nil : d.defaultValue, d.isGenerated ? d.generatedStorage.rawValue + " (" + d.generationExpression + ")" : d.extraDisplayValue, d.comment]
            }); changes = draft.state.columns.map(\.isModified); deletions = draft.state.columns.map(\.isDeleted)
        } else {
            result = .init(columns: ["名称", "种类", "字段", "方法", "可见", "注释"], rows: draft.state.indexes.map { item in
                let d = item.definition
                return [d.kind == .primary ? "PRIMARY" : d.name, d.kind.rawValue.uppercased(), d.columns.map { $0.name + ($0.prefixLength.isEmpty ? "" : "(" + $0.prefixLength + ")") + ($0.isDescending ? " DESC" : "") }.joined(separator: ", "), d.method, d.isVisible ? "是" : "否", d.comment]
            }); changes = draft.state.indexes.map(\.isModified); deletions = draft.state.indexes.map(\.isDeleted)
        }
        for row in changes.indices {
            if deletions[row] { result.deletedRows.insert(row) }
            if changes[row] { for column in result.columns.indices { result.pendingCells.insert(.init(row: row, column: column)) } }
        }
        return result
    }
}

private extension WorkspaceDatabaseSchemaEditorState.ColumnItem {
    var schemaPresentationID: String { original.map { "column:" + $0.name } ?? "new:" + id.uuidString }
}
private extension WorkspaceDatabaseSchemaEditorState.IndexItem {
    var schemaPresentationID: String { original.map { "index:" + $0.name } ?? "new:" + id.uuidString }
}
