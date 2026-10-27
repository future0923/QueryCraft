import SwiftUI
import UIKit

struct MobileDataExportView: View {
    @Bindable var model: MobileDataExportModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var saving = false
    @FocusState private var focusedInput: MobileExportInput?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.snapshot.allRowsProvider != nil {
                        Picker("范围", selection: $model.scope) {
                            Text(model.snapshot.scopeDescription).tag(WorkspaceDataExportScope.currentData)
                            Text(model.snapshot.allRowsLabel).tag(WorkspaceDataExportScope.allTableRows)
                        }.accessibilityIdentifier("dataExportScope")
                    } else { LabeledContent("范围", value: model.snapshot.scopeDescription) }
                    LabeledContent("行数", value: model.scope == .allTableRows ? "生成时统计" : "\(model.snapshot.data.rows.count)")
                    Picker("格式", selection: $model.format) {
                        ForEach(WorkspaceDataExportFormat.allCases.filter { $0 != .sql || model.snapshot.sqlDialect != nil }) { Text($0.menuTitle).tag($0) }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.scope == .allTableRows {
                            if model.snapshot.isQueryCache {
                                Text("分批导出本次查询的磁盘缓存，不会重新执行 SQL。")
                            } else {
                            Text("按打开导出时的筛选与排序分批读取全部数据，时间戳保持原始值。")
                            Text("分批读取期间服务器的数据变化可能影响结果。")
                            }
                        } else { Text("仅导出已加载的服务器数据，不包含暂存修改；时间戳保持原始值。") }
                        if model.snapshot.hasBinaryValues, model.format != .sql {
                            Text("二进制仅导出字节数说明，不包含完整字节。")
                        }
                    }
                }
                if model.format == .sql {
                    Section {
                        LabeledContent("目标表") {
                            TextField("请输入表名", text: $model.sqlTableName).multilineTextAlignment(.trailing)
                                .focused($focusedInput, equals: .target).submitLabel(.done)
                        }
                        if model.snapshot.tableIdentifierParts != nil {
                            Toggle(model.snapshot.sqlDialect == .postgresql ? "包含 Schema 名" : "包含数据库名", isOn: $model.preferences.sqlIncludesDatabaseName)
                        }
                    } footer: { Text("生成 INSERT 文件，不会执行 SQL。二进制字段不支持 SQL 导出。") }
                }
                Section {
                    DisclosureGroup("文件选项") { formatOptions }
                }
                Section {
                    HStack {
                        ProgressView().opacity(model.isExporting ? 1 : 0).accessibilityHidden(!model.isExporting)
                        Text(model.isExporting ? "已处理 \(model.completedRows) 行" : (model.file == nil ? "准备就绪" : "文件已生成"))
                            .foregroundStyle(.secondary)
                    }.frame(height: 24)
                    if let message = model.message { Text(message).foregroundStyle(.red) }
                    Button(model.file == nil ? "生成并存储文件" : "存储文件", systemImage: "square.and.arrow.down") {
                        focusedInput = nil
                        if model.file != nil { saving = true } else { model.prepare() }
                    }.disabled(!model.canPrepare).accessibilityIdentifier("prepareDataExport")
                }
            }
            .disabled(model.isExporting)
            .scrollDismissesKeyboard(.immediately)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .onSubmit { focusedInput = nil }
            .navigationTitle("导出数据").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(model.isExporting ? "取消导出" : "关闭") { model.cancel(); dismiss() }
            } }
        }
        .sheet(isPresented: $saving) {
            if let file = model.file {
                MobileNativeExportPicker(url: file.url) { saving = false }
                    .ignoresSafeArea()
            }
        }
        .onChange(of: model.file?.id) { _, id in if id != nil { saving = true } }
        .onChange(of: model.scope) { _, _ in model.cancel() }
        .onChange(of: model.format) { _, _ in model.cancel() }
        .onChange(of: model.preferences) { _, _ in model.cancel() }
        .onChange(of: model.sqlTableName) { _, _ in model.cancel() }
        .onChange(of: model.worksheetName) { _, _ in model.cancel() }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase != .inactive { model.setBackgrounded(phase == .background) }
        }
        .accessibilityIdentifier("dataExportOptions")
    }

    private var formatOptions: some View {
        MobileExportOptionsFields(preferences: $model.preferences, format: model.format,
            sqlDialect: model.snapshot.sqlDialect, worksheetName: $model.worksheetName, focusedInput: $focusedInput)
    }

}

/// Export the committed file URL directly. FileDocument/FileWrapper would load
/// the entire file into memory, defeating bounded whole-table export at save time.
struct MobileNativeExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onClose() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onClose() }
    }
}
