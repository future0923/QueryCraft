import SwiftUI
import QueryCraftMobileCore

/// A compact record presentation for narrow screens; the grid remains available.
struct MobileRecordList: View {
    @Bindable var preferences: MobilePreferences = .shared
    let data: MobileGridData
    let revision: String
    @Binding var scrollID: Int?
    let selectRecord: (Int) -> Void
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(data.rows.indices, id: \.self) { row in
                    Button {
                        selectRecord(row)
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(data.columns.indices.prefix(4), id: \.self) { column in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(data.columns[column]).font(.caption).foregroundStyle(.secondary)
                                            .frame(width: 84, alignment: .leading).lineLimit(1)
                                        Text(data.cell(row: row, column: column).gridPreviewText(nullDisplayText: preferences.nullStyle.displayText, emptyStringDisplayText: preferences.emptyStringStyle.displayText, maximumCharacterCount: 120))
                                            .font(column == 0 ? .subheadline.weight(.semibold) : .system(.caption, design: .monospaced))
                                            .foregroundStyle(data.cell(row: row, column: column) == .null ? .secondary : .primary)
                                            .lineLimit(1)
                                    }
                                }
                                if data.columns.count > 4 {
                                    Text("还有 \(data.columns.count - 4) 个字段").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.padding(.horizontal, 16).padding(.vertical, 14).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .background(data.deletedRows.contains(row) ? Color.red.opacity(0.10)
                            : (data.pendingCells.contains(where: { $0.row == row }) ? Color.yellow.opacity(0.12) : Color(uiColor: .systemBackground)), in: .rect(cornerRadius: 14))
                        .id(row).accessibilityIdentifier("recordRow.\(row)")
                }
            }.scrollTargetLayout()
        }.scrollPosition(id: $scrollID, anchor: .top)
        // Retain scroll identity during refresh; object changes create a new enclosing context.
        .accessibilityIdentifier("recordList")
    }
}

@MainActor struct MobileRecordSelection: Identifiable {
    let id = UUID()
    let row: Int
    let source: MobileResultSource
    let generation: UUID
    init(row: Int, source: MobileResultSource) {
        self.row = row; self.source = source; generation = source.generation
    }
}

struct MobileRecordInspector: View {
    @Bindable var preferences: MobilePreferences = .shared
    let selection: MobileRecordSelection
    @Environment(\.dismiss) private var dismiss
    @State private var cellPresentation: MobileResultCellPresentation?
    @State private var pendingChanges: MobileTableChanges?
    @State private var message: String?
    @State private var detent: PresentationDetent = .large
    private var source: MobileResultSource { selection.source }
    var body: some View {
        let data = source.data
        NavigationStack {
            List {
                if let message { Text(message).font(.footnote).foregroundStyle(.red) }
                if data.deletedRows.contains(selection.row) { Text("此行已暂存删除，可在菜单中恢复。") .foregroundStyle(.red) }
                ForEach(data.columns.indices, id: \.self) { column in
                    Section {
                        value(data.cell(row: selection.row, column: column))
                    } header: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(data.columns[column])
                                if preferences.showsInspectorDetails, data.details.indices.contains(column), !data.details[column].isEmpty {
                                    Text(data.details[column]).font(.caption2).lineLimit(2)
                                }
                            }
                            Spacer()
                            if data.pendingCells.contains(.init(row: selection.row, column: column)) {
                                Text("待提交").font(.caption2).foregroundStyle(.orange)
                            }
                            let editable = (try? source.edit(row: selection.row, column: column)) != nil
                            Button(editable ? "编辑字段" : "查看字段", systemImage: editable ? "pencil" : "info.circle") {
                                guard source.isCurrent, source.generation == selection.generation else { dismiss(); return }
                                cellPresentation = source.cell(row: selection.row, column: column)
                            }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                .accessibilityLabel((editable ? "编辑 " : "查看 ") + data.columns[column])
                                .accessibilityIdentifier("recordFieldAction.\(column)")
                        }
                    }
                }
            }.navigationTitle("第 \(selection.row + 1) 行").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let changes = source.snapshot.editing {
                            if changes.hasChanges {
                                Button("待提交改动", systemImage: "square.and.pencil") { pendingChanges = changes }
                                    .accessibilityIdentifier("recordPendingChanges")
                            }
                            Menu {
                                Button(data.deletedRows.contains(selection.row) ? "恢复此行" : "暂存删除此行", systemImage: "trash") {
                                    do {
                                        try source.validate(selection.generation)
                                        guard let page = source.snapshot.page else { return }
                                        try changes.toggleDelete(page: page, row: selection.row)
                                    } catch { message = error.localizedDescription }
                                }.disabled(!source.canEdit || changes.isSubmitting)
                            } label: { Label("行操作", systemImage: "ellipsis") }
                        }
                    }
                }
        }
        .sheet(item: $cellPresentation) { MobileResultCellSheet(presentation: $0) }
        .sheet(item: $pendingChanges) { MobilePendingChangesView(changes: $0) }
        .onChange(of: source.generation) { _, _ in dismiss() }
        .onChange(of: source.isCurrent) { _, current in if !current { dismiss() } }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_SURFACE"] == "record-cell" {
                cellPresentation = source.cell(row: selection.row, column: 1)
            }
            #endif
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .accessibilityIdentifier("recordInspector")
    }

    @ViewBuilder private func value(_ cell: WorkspaceDatabaseDataCell) -> some View {
        switch cell {
        case .null: Text(preferences.nullStyle.displayText).foregroundStyle(.secondary).accessibilityLabel("NULL")
        case .text(let value):
            let preview = WorkspaceDatabaseDataCell.boundedPreview(value, maximumCharacterCount: 16_384)
            Text(value.isEmpty ? preferences.emptyStringStyle.displayText : preview)
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            if preview != value {
                Text("预览前 16,384 个字符。").font(.footnote).foregroundStyle(.secondary)
                ShareLink(item: value) { Label("分享完整文本", systemImage: "square.and.arrow.up") }
            }
        case .binary(let count, let bytes):
            Text("二进制 · \(count) bytes").font(.subheadline)
            Text(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("最多预览 128 bytes").font(.caption).foregroundStyle(.secondary)
        }
    }
}
