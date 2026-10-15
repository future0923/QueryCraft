import SwiftUI

struct DataExportSettingsSections: View {
    @Bindable var preferences: ApplicationPreferences

    var body: some View {
        Section(AppCopy.current.text("导出 · 通用", "Export · General")) {
            Text(AppCopy.current.text(
                "右键表选择格式后直接保存文件，导出时使用以下设置。",
                "Table context-menu exports save directly using these settings."
            ))
            .foregroundStyle(.secondary)
            Toggle(AppCopy.current.text("CSV / XLSX 包含列名", "Include CSV / XLSX Column Names"),
                   isOn: $preferences.dataExport.includesColumnNames)
            Picker(AppCopy.current.text("CSV / XLSX 的 NULL 值", "CSV / XLSX NULL Values"),
                   selection: $preferences.dataExport.nullStyle) {
                Text("NULL").tag(WorkspaceDataExportNullStyle.literal)
                Text(AppCopy.current.text("空值", "Empty")).tag(WorkspaceDataExportNullStyle.empty)
            }
        }
        Section("CSV") {
            Picker(AppCopy.current.text("分隔符", "Delimiter"), selection: $preferences.dataExport.csvDelimiter) {
                Text(AppCopy.current.text("逗号", "Comma")).tag(WorkspaceCSVDelimiter.comma)
                Text(AppCopy.current.text("制表符", "Tab")).tag(WorkspaceCSVDelimiter.tab)
                Text(AppCopy.current.text("分号", "Semicolon")).tag(WorkspaceCSVDelimiter.semicolon)
                Text(AppCopy.current.text("竖线", "Pipe")).tag(WorkspaceCSVDelimiter.pipe)
            }
            Picker(AppCopy.current.text("换行符", "Line Ending"), selection: $preferences.dataExport.csvLineEnding) {
                Text("Windows (CRLF)").tag(WorkspaceCSVLineEnding.crlf)
                Text("Unix (LF)").tag(WorkspaceCSVLineEnding.lf)
            }
            Picker(AppCopy.current.text("文本引号", "Text Quotes"), selection: $preferences.dataExport.csvQuotePolicy) {
                Text(AppCopy.current.text("按需添加", "As Needed")).tag(WorkspaceCSVQuotePolicy.asNeeded)
                Text(AppCopy.current.text("所有文本", "All Text")).tag(WorkspaceCSVQuotePolicy.allText)
            }
            Toggle("UTF-8 BOM", isOn: $preferences.dataExport.csvIncludesUTF8BOM)
            Toggle(AppCopy.current.text("防止表格公式执行", "Prevent Spreadsheet Formulas"),
                   isOn: $preferences.dataExport.sanitizesSpreadsheetFormulas)
        }
        Section("JSON") {
            Picker(AppCopy.current.text("数据结构", "Data Layout"), selection: $preferences.dataExport.jsonLayout) {
                Text(AppCopy.current.text("对象数组", "Array of Objects")).tag(WorkspaceJSONLayout.objects)
                Text(AppCopy.current.text("表格结构", "Tabular")).tag(WorkspaceJSONLayout.tabular)
                Text("JSON Lines (.jsonl)").tag(WorkspaceJSONLayout.lines)
            }
            Toggle(AppCopy.current.text("格式化 JSON", "Pretty-print JSON"),
                   isOn: $preferences.dataExport.prettyPrintsJSON)
                .disabled(preferences.dataExport.jsonLayout == .lines)
        }
        Section("SQL INSERT") {
            DataExportBatchSizeField(value: $preferences.dataExport.sqlInsertBatchSize)
            Toggle(AppCopy.current.text("包含数据库 / Schema 名", "Include Database / Schema Name"),
                   isOn: $preferences.dataExport.sqlIncludesDatabaseName)
            Toggle(isOn: $preferences.dataExport.sqlWrapsInTransaction) {
                SettingsControlLabel(
                    title: AppCopy.current.text("使用事务", "Use Transaction"),
                    description: AppCopy.current.text("适用于 MySQL 和 PostgreSQL。", "Applies to MySQL and PostgreSQL.")
                )
            }
        }
        Section("XLSX") {
            Toggle(AppCopy.current.text("冻结标题行", "Freeze Header Row"),
                   isOn: $preferences.dataExport.xlsxFreezesHeader)
                .disabled(!preferences.dataExport.includesColumnNames)
            Toggle(AppCopy.current.text("自动筛选", "Auto Filter"),
                   isOn: $preferences.dataExport.xlsxAddsAutoFilter)
                .disabled(!preferences.dataExport.includesColumnNames)
        }
    }
}
