import SwiftUI

enum MobileExportInput: Hashable { case target, worksheet, batch }

/// Shared by per-export options and persisted defaults. Changing a single
/// export keeps its captured settings local to that export.
struct MobileExportOptionsFields: View {
    @Binding var preferences: WorkspaceDataExportPreferences
    let format: WorkspaceDataExportFormat
    var sqlDialect: WorkspaceSQLExportDialect? = .mysql
    var worksheetName: Binding<String>? = nil
    @FocusState.Binding var focusedInput: MobileExportInput?
    var body: some View {
        switch format {
        case .csv:
            Toggle("包含字段名", isOn: $preferences.includesColumnNames)
            nullPicker
            Toggle("UTF-8 BOM", isOn: $preferences.csvIncludesUTF8BOM)
            Picker("分隔符", selection: $preferences.csvDelimiter) {
                Text("逗号").tag(WorkspaceCSVDelimiter.comma)
                Text("Tab").tag(WorkspaceCSVDelimiter.tab)
                Text("分号").tag(WorkspaceCSVDelimiter.semicolon)
                Text("竖线").tag(WorkspaceCSVDelimiter.pipe)
            }
            Picker("换行", selection: $preferences.csvLineEnding) {
                Text("CRLF").tag(WorkspaceCSVLineEnding.crlf); Text("LF").tag(WorkspaceCSVLineEnding.lf)
            }
            Picker("引号", selection: $preferences.csvQuotePolicy) {
                Text("按需").tag(WorkspaceCSVQuotePolicy.asNeeded); Text("所有文本").tag(WorkspaceCSVQuotePolicy.allText)
            }
            Toggle("防止电子表格公式执行", isOn: $preferences.sanitizesSpreadsheetFormulas)
        case .json:
            Picker("布局", selection: $preferences.jsonLayout) {
                Text("对象数组").tag(WorkspaceJSONLayout.objects)
                Text("字段与行").tag(WorkspaceJSONLayout.tabular)
                Text("逐行 JSON").tag(WorkspaceJSONLayout.lines)
            }
            if preferences.jsonLayout != .lines { Toggle("格式化 JSON", isOn: $preferences.prettyPrintsJSON) }
        case .xlsx:
            Toggle("包含字段名", isOn: $preferences.includesColumnNames)
            nullPicker
            if let worksheetName { LabeledContent("工作表名") {
                TextField("结果", text: worksheetName).multilineTextAlignment(.trailing).submitLabel(.done)
                    .focused($focusedInput, equals: .worksheet)
            }
            }
            Toggle("冻结表头", isOn: $preferences.xlsxFreezesHeader)
            Toggle("自动筛选", isOn: $preferences.xlsxAddsAutoFilter)
        case .sql:
            LabeledContent("每条语句行数") {
                TextField("1000", value: $preferences.sqlInsertBatchSize, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).submitLabel(.done)
                    .focused($focusedInput, equals: .batch)
            }
            if sqlDialect != .doris { Toggle("事务包装", isOn: $preferences.sqlWrapsInTransaction) }
        }
    }

    private var nullPicker: some View {
        Picker("NULL 显示", selection: $preferences.nullStyle) {
            Text("NULL").tag(WorkspaceDataExportNullStyle.literal); Text("空白").tag(WorkspaceDataExportNullStyle.empty)
        }
    }
}
