import SwiftUI

/// The table owns scrolling. Nesting it in the grouped Form's scroll view
/// competes for wheel events and gives the table a fixed, clipped viewport.
struct MCPActivitySettingsPane: View {
    @Bindable var model: MCPSettingsModel
    @State private var selectedID: String?
    @State private var confirmClear = false
    private let strings = AppCopy.current
    private func copy(_ zh: String, _ en: String) -> String { strings.text(zh, en) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { model.policy.tuning.recordsHistory }, set: { value in model.updateOptimizations { $0.recordsHistory = value } })) {
                        MCPSettingsControlLabel(title: copy("记录调用摘要", "Record call summaries"),
                            description: copy("最多 500 条。不保存 SQL、参数、密码或结果正文。", "Up to 500 summaries. SQL, arguments, credentials and result bodies are excluded."))
                    }.toggleStyle(.switch)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .scrollDisabled(true)
            .frame(height: 100)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(copy("最近调用", "Recent calls")).font(.headline)
                    Spacer()
                    Text(copy("\(model.historyRows.count) 条", "\(model.historyRows.count) calls"))
                        .font(MCPSettingsType.detail).foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                GeometryReader { geometry in
                    Table(model.historyRows, selection: $selectedID) {
                        TableColumn(copy("工具", "Tool")) { row in
                            Label(row.tool.replacingOccurrences(of: "querycraft_", with: ""),
                                  systemImage: row.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                                .help(row.errorCode ?? copy("成功", "Succeeded"))
                        }
                        TableColumn(copy("时间", "Time")) { row in Text(row.startedAt, style: .time) }.width(70)
                        TableColumn(copy("耗时", "Duration")) { row in Text("\(row.durationMilliseconds) ms").monospacedDigit() }.width(70)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: true))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay {
                        if model.historyLoaded && model.historyRows.isEmpty && !model.historyLoading && model.historyError == nil {
                            Text(copy("暂无调用记录", "No calls recorded")).foregroundStyle(.secondary).allowsHitTesting(false)
                        }
                    }
                }
                .frame(minHeight: 100)
                .layoutPriority(1)

                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16).opacity(model.historyLoading ? 1 : 0)
                    Text(model.historyError ?? copy("重新检查以更新记录。", "Check again to update calls."))
                        .font(MCPSettingsType.detail).foregroundStyle(model.historyError == nil ? Color.secondary : .red)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Button(copy("清空记录…", "Clear calls…"), role: .destructive) { confirmClear = true }
                        .disabled(model.historyLoading || model.historyRows.isEmpty)
                }
                .frame(height: 32)

                GroupBox {
                    VStack(alignment: .leading, spacing: 5) {
                        if let row = model.historyRows.first(where: { $0.id == selectedID }) {
                            Text(row.tool).monospaced().lineLimit(1).truncationMode(.middle)
                            Text(row.startedAt.formatted(date: .abbreviated, time: .standard) + " · " + (row.errorCode ?? "\(row.resultBytes) B"))
                                .foregroundStyle(.secondary).lineLimit(1)
                            if let id = row.connectionID { Text(id).monospaced().lineLimit(1).truncationMode(.middle) }
                        } else {
                            Text(copy("选择一条记录查看详情。", "Select a call to view its details.")).foregroundStyle(.secondary)
                        }
                    }
                    .font(MCPSettingsType.detail).textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 66, maxHeight: 66, alignment: .topLeading)
                    .padding(4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .confirmationDialog(copy("清空 MCP 调用记录？", "Clear MCP call history?"), isPresented: $confirmClear) {
            Button(copy("清空记录", "Clear history"), role: .destructive) { Task { await model.clearHistory() } }
        }
    }
}
