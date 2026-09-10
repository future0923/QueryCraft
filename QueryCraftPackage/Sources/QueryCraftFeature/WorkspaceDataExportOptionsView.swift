import SwiftUI

struct WorkspaceDataExportOptionsView: View {
    @Bindable var controller: WorkspaceDataExportController
    @State private var preferences = ApplicationPreferences.shared
    @State private var showsAdvancedOptions = false

    private enum Layout {
        static let controlColumnWidth: CGFloat = 300
        static let columnSpacing: CGFloat = 24
        static let rowSpacing: CGFloat = 12
        static let minimumRowHeight: CGFloat = 26
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.vertical, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    fileSection
                    if controller.hasMultipleExportScopes {
                        sectionDivider
                        scopeSection
                    }
                    sectionDivider
                    formatContentSection
                    if hasAdvancedOptions {
                        sectionDivider
                        advancedSection
                    }
                }
                .padding(24)
            }
            .scrollContentBackground(.visible)

            Divider()

            actions
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 600, height: 590)
        .background(.background)
        .environment(\.locale, preferences.interfaceLocale)
        .accessibilityIdentifier("dataExportConfigurationSheet")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppCopy.current.text("导出数据", "Export Data"))
                    .font(.title3)
                    .bold()
                Text(
                    AppCopy.current.text(
                        "选择导出格式和文件内容。",
                        "Choose the export format and file contents."
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(AppCopy.current.text("文件格式", "File Format"))

            optionGrid {
                optionRow(AppCopy.current.text("格式", "Format")) {
                    Picker(
                        AppCopy.current.text("格式", "Format"),
                        selection: $controller.options.format
                    ) {
                        Text("Excel").tag(WorkspaceDataExportFormat.xlsx)
                        Text("CSV").tag(WorkspaceDataExportFormat.csv)
                        Text("JSON").tag(WorkspaceDataExportFormat.json)
                        Text("SQL").tag(WorkspaceDataExportFormat.sql)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(AppCopy.current.text("数据范围", "Data Scope"))

            optionGrid {
                optionRow(AppCopy.current.text("范围", "Scope")) {
                    Picker(
                        AppCopy.current.text("范围", "Scope"),
                        selection: $controller.options.scope
                    ) {
                        Text(controller.allRowsTitle)
                            .tag(WorkspaceDataExportScope.currentData)
                        if controller.supportsAllTableRows {
                            Text(controller.allTableRowsTitle)
                                .tag(WorkspaceDataExportScope.allTableRows)
                        }
                        if controller.hasSelection {
                            Text(controller.selectionTitle)
                                .tag(WorkspaceDataExportScope.selection)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }
    }

    @ViewBuilder
    private var formatContentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(sectionName)

            optionGrid {
                switch controller.options.format {
                case .xlsx, .csv:
                    optionRow(
                        AppCopy.current.text("包含列名", "Include Column Names")
                    ) {
                        Toggle(
                            AppCopy.current.text(
                                "包含列名",
                                "Include Column Names"
                            ),
                            isOn: $controller.options.includesColumnNames
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    optionRow(AppCopy.current.text("NULL 值", "NULL Values")) {
                        Picker(
                            AppCopy.current.text("NULL 值", "NULL Values"),
                            selection: $controller.options.nullStyle
                        ) {
                            Text("NULL")
                                .tag(WorkspaceDataExportNullStyle.literal)
                            Text(AppCopy.current.text("空值", "Empty"))
                                .tag(WorkspaceDataExportNullStyle.empty)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                case .json:
                    optionRow(AppCopy.current.text("数据结构", "Data Layout")) {
                        Picker(
                            AppCopy.current.text("JSON 结构", "JSON Layout"),
                            selection: $controller.options.jsonLayout
                        ) {
                            Text(AppCopy.current.text("表格结构", "Tabular"))
                                .tag(WorkspaceJSONLayout.tabular)
                            Text(
                                AppCopy.current.text(
                                    "对象数组",
                                    "Array of Objects"
                                )
                            )
                            .tag(WorkspaceJSONLayout.objects)
                            Text("JSON Lines")
                                .tag(WorkspaceJSONLayout.lines)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    if controller.options.jsonLayout != .lines {
                        optionRow(
                            AppCopy.current.text("格式化", "Pretty Print")
                        ) {
                            Toggle(
                                AppCopy.current.text(
                                    "格式化 JSON",
                                    "Pretty-print JSON"
                                ),
                                isOn: $controller.options.prettyPrintsJSON
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                case .sql:
                    optionRow(AppCopy.current.text("表名", "Table Name")) {
                        WorkspaceDataExportInlineTextField(
                            title: AppCopy.current.text("表名", "Table Name"),
                            prompt: AppCopy.current.text(
                                "例如：schema.table",
                                "For example: schema.table"
                            ),
                            text: $controller.options.sqlTableName
                        )
                    }
                    optionRow(
                        AppCopy.current.text("插入语句", "Insert Statement")
                    ) {
                        Picker(
                            AppCopy.current.text(
                                "插入语句",
                                "Insert Statement"
                            ),
                            selection:
                                $controller.options.sqlConflictStrategy
                        ) {
                            Text(
                                AppCopy.current.text(
                                    "INSERT（追加）",
                                    "INSERT (Append)"
                                )
                            )
                            .tag(WorkspaceSQLConflictStrategy.insert)
                            Text(
                                AppCopy.current.text(
                                    "INSERT IGNORE（忽略冲突）",
                                    "INSERT IGNORE (Skip Conflicts)"
                                )
                            )
                            .tag(WorkspaceSQLConflictStrategy.ignore)
                            Text(
                                AppCopy.current.text(
                                    "REPLACE（替换）",
                                    "REPLACE (Replace)"
                                )
                            )
                            .tag(WorkspaceSQLConflictStrategy.replace)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(
            isExpanded: $showsAdvancedOptions
        ) {
            advancedOptions
                .padding(.top, 14)
        } label: {
            sectionTitle(
                AppCopy.current.text("高级选项", "Advanced Options")
            )
        }
        .disclosureGroupStyle(WorkspaceDataExportDisclosureGroupStyle())
    }

    @ViewBuilder
    private var advancedOptions: some View {
        optionGrid {
            switch controller.options.format {
            case .xlsx:
                optionRow(
                    AppCopy.current.text("工作表名称", "Worksheet Name")
                ) {
                    WorkspaceDataExportInlineTextField(
                        title: AppCopy.current.text(
                            "工作表名称",
                            "Worksheet Name"
                        ),
                        prompt: AppCopy.current.text(
                            "使用导出名称",
                            "Use Export Name"
                        ),
                        text: $controller.options.xlsxWorksheetName
                    )
                }
                optionRow(
                    AppCopy.current.text("冻结标题行", "Freeze Header Row")
                ) {
                    Toggle(
                        AppCopy.current.text(
                            "冻结标题行",
                            "Freeze Header Row"
                        ),
                        isOn: $controller.options.xlsxFreezesHeader
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!controller.options.includesColumnNames)
                }
                optionRow(
                    AppCopy.current.text("自动筛选", "Auto Filter")
                ) {
                    Toggle(
                        AppCopy.current.text(
                            "添加自动筛选",
                            "Add Auto Filter"
                        ),
                        isOn: $controller.options.xlsxAddsAutoFilter
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!controller.options.includesColumnNames)
                }
            case .csv:
                optionRow(AppCopy.current.text("分隔符", "Delimiter")) {
                    Picker(
                        AppCopy.current.text("分隔符", "Delimiter"),
                        selection: $controller.options.csvDelimiter
                    ) {
                        Text(AppCopy.current.text("逗号", "Comma"))
                            .tag(WorkspaceCSVDelimiter.comma)
                        Text(AppCopy.current.text("制表符", "Tab"))
                            .tag(WorkspaceCSVDelimiter.tab)
                        Text(AppCopy.current.text("分号", "Semicolon"))
                            .tag(WorkspaceCSVDelimiter.semicolon)
                        Text(AppCopy.current.text("竖线", "Pipe"))
                            .tag(WorkspaceCSVDelimiter.pipe)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                optionRow(AppCopy.current.text("换行符", "Line Ending")) {
                    Picker(
                        AppCopy.current.text("换行符", "Line Ending"),
                        selection: $controller.options.csvLineEnding
                    ) {
                        Text("Windows (CRLF)")
                            .tag(WorkspaceCSVLineEnding.crlf)
                        Text("Unix (LF)")
                            .tag(WorkspaceCSVLineEnding.lf)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                optionRow(AppCopy.current.text("文本引号", "Text Quotes")) {
                    Picker(
                        AppCopy.current.text("引号", "Quotes"),
                        selection: $controller.options.csvQuotePolicy
                    ) {
                        Text(AppCopy.current.text("按需添加", "As Needed"))
                            .tag(WorkspaceCSVQuotePolicy.asNeeded)
                        Text(AppCopy.current.text("所有文本", "All Text"))
                            .tag(WorkspaceCSVQuotePolicy.allText)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                optionRow("UTF-8 BOM") {
                    Toggle(
                        AppCopy.current.text(
                            "包含 UTF-8 BOM",
                            "Include UTF-8 BOM"
                        ),
                        isOn: $controller.options.csvIncludesUTF8BOM
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                optionRow(
                    AppCopy.current.text("公式保护", "Formula Protection")
                ) {
                    Toggle(
                        AppCopy.current.text(
                            "防止表格公式执行",
                            "Prevent Spreadsheet Formulas"
                        ),
                        isOn: $controller.options.sanitizesSpreadsheetFormulas
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            case .json:
                EmptyView()
            case .sql:
                optionRow(
                    AppCopy.current.text(
                        "单条语句行数",
                        "Rows per Statement"
                    )
                ) {
                    Picker(
                        AppCopy.current.text(
                            "单条语句行数",
                            "Rows per Statement"
                        ),
                        selection: $controller.options.sqlInsertBatchSize
                    ) {
                        Text(AppCopy.current.text("100 行", "100 rows"))
                            .tag(100)
                        Text(AppCopy.current.text("500 行", "500 rows"))
                            .tag(500)
                        Text(AppCopy.current.text("1,000 行", "1,000 rows"))
                            .tag(1_000)
                        Text(AppCopy.current.text("5,000 行", "5,000 rows"))
                            .tag(5_000)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                optionRow(AppCopy.current.text("使用事务", "Use Transaction")) {
                    Toggle(
                        AppCopy.current.text(
                            "使用事务",
                            "Use Transaction"
                        ),
                        isOn: $controller.options.sqlWrapsInTransaction
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button(
                AppCopy.current.text("打开导出中心", "Open Export Center"),
                systemImage: "arrow.down.doc",
                action: WorkspaceDataExportCenterWindowController.show
            )
            .labelStyle(.iconOnly)
            .help(
                AppCopy.current.text(
                    "打开导出中心",
                    "Open Export Center"
                )
            )

            Spacer()

            Button(
                AppCopy.current.text("取消", "Cancel"),
                action: controller.cancelOptions
            )
            .keyboardShortcut(.cancelAction)

            Button(
                AppCopy.current.text("导出…", "Export..."),
                action: controller.chooseDestinationAndExport
            )
            .keyboardShortcut(.defaultAction)
            .disabled(
                controller.options.format == .sql
                    && controller.options.sqlTableName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
        }
    }

    private var sectionName: String {
        switch controller.options.format {
        case .xlsx, .csv:
            AppCopy.current.text("数据内容", "Data Content")
        case .json:
            "JSON"
        case .sql:
            AppCopy.current.text("SQL 输出", "SQL Output")
        }
    }

    private var hasAdvancedOptions: Bool {
        controller.options.format != .json
    }

    private var sectionDivider: some View {
        Divider()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private func optionGrid<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private func optionRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: Layout.columnSpacing) {
            Text(title)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
                .frame(
                    width: Layout.controlColumnWidth,
                    alignment: .trailing
                )
        }
        .frame(minHeight: Layout.minimumRowHeight)
        .frame(maxWidth: .infinity)
    }
}
