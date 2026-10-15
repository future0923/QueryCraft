import AppKit
import SwiftUI

struct WorkspaceDataImportView: View {
    @Bindable var model: WorkspaceDataImportModel
    let close: @MainActor () -> Void
    private func t(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t("目标表", "Target Table")).font(.caption).foregroundStyle(.secondary)
                        Text(model.targetLabel).font(.headline).textSelection(.enabled).lineLimit(2)
                    }
                    Spacer()
                    if model.step != .execution {
                        Button(t(model.fileURL == nil ? "选择文件…" : "更换文件…", model.fileURL == nil ? "Choose File…" : "Change File…"), systemImage: "folder", action: model.chooseFile)
                            .disabled(model.isLoading)
                    }
                }
                HStack(spacing: 10) {
                    Text("\(model.step.rawValue + 1) / \(WorkspaceDataImportModel.Step.allCases.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 34, alignment: .leading)
                    ProgressView(value: Double(model.step.rawValue), total: Double(max(1, WorkspaceDataImportModel.Step.allCases.count - 1)))
                        .tint(.accentColor)
                    Text(model.step.title)
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 56, alignment: .trailing)
                }
                HStack {
                    ForEach(WorkspaceDataImportModel.Step.allCases) { step in
                        Text(step.title)
                            .font(.caption)
                            .foregroundStyle(step.rawValue <= model.step.rawValue ? .primary : .tertiary)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(step.title + (step == model.step ? t("，当前步骤", ", current step") : ""))
                    }
                }
            }.padding(20)
            Divider()
            Group {
                switch model.step {
                case .source: source
                case .options: options
                case .mapping: mapping
                case .confirmation: confirmation
                case .execution: execution
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            VStack(alignment: .leading, spacing: 4) {
                if model.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.loadingMessage).font(.callout).foregroundStyle(.secondary)
                    }
                }
                else if !model.errorMessage.isEmpty {
                    ScrollView { Text(model.errorMessage).foregroundStyle(.red).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.frame(height: 50, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 760, minHeight: 580)
    }

    private var source: some View {
        VStack(spacing: 24) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(t("选择文件导入到现有表", "Choose a file to import into this table")).font(.title3)
            Button(t("选择文件…", "Choose File…"), action: model.chooseFile).buttonStyle(.borderedProminent)
            Text("CSV · TSV · JSON / JSONL · XLSX / XLSM · SQL INSERT").foregroundStyle(.secondary)
            Text(t("支持自定义分隔文本；旧版 XLS 请先另存为 XLSX。", "Custom delimiters are supported. Save legacy XLS as XLSX first.")).font(.caption).foregroundStyle(.secondary)
            Text(t("按文件内容和数据库能力导入，不设置人为文件大小上限。", "Imports follow the file content and database capacity without an artificial file-size limit.")).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var options: some View {
        Form {
            LabeledContent(t("源文件", "Source File"), value: model.fileURL?.lastPathComponent ?? "—")
            Picker(t("源格式", "Format"), selection: Binding(get: { model.options.format }, set: { model.setFormat($0) })) {
                ForEach(WorkspaceDataImportFormat.allCases) { Text($0.title).tag($0) }
            }
            if model.options.format != .excel {
                Picker(t("文件编码", "Encoding"), selection: $model.options.encoding) {
                    ForEach(WorkspaceDataImportOptions.Encoding.allCases) { Text($0.title).tag($0) }
                }
            }
            if model.options.format.isDelimited {
                TextField(t("分隔符", "Delimiter"), text: $model.options.delimiter).disabled(model.options.format == .tsv)
            }
            if model.options.format == .excel {
                if let names = model.file?.sheetNames, !names.isEmpty {
                    Picker(t("工作表", "Worksheet"), selection: $model.options.sheetIndex) {
                        ForEach(Array(names.enumerated()), id: \.element) { Text($0.element).tag($0.offset) }
                    }
                } else {
                    Stepper(t("工作表序号：\(model.options.sheetIndex + 1)", "Worksheet number: \(model.options.sheetIndex + 1)"), value: $model.options.sheetIndex, in: 0...999)
                }
                Text(t("读取公式缓存结果，不执行公式或宏。", "Uses cached formula results; formulas and macros are not executed.")).font(.caption).foregroundStyle(.secondary)
            }
            if model.options.format.usesRows {
                HStack {
                    integerField(t("标题行（0 为无）", "Header Row (0 = none)"), value: $model.options.headerRow)
                    integerField(t("数据起始行", "First Data Row"), value: $model.options.firstDataRow)
                    integerField(t("最后行（0 为末尾）", "Last Row (0 = end)"), value: $model.options.lastDataRow)
                }
                if model.options.format == .json {
                    Text(t("JSON 对象自带字段名；起始行 1 表示第一条记录。数组行可指定标题行。", "Objects provide column names. Row 1 is the first record; array rows can use a header row.")).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(t("去除前后空白", "Trim Whitespace"), isOn: $model.options.trimsWhitespace)
                Toggle(t("空字符串作为 NULL", "Treat Empty Strings as NULL"), isOn: $model.options.emptyAsNull)
            }
            if model.options.format.isDelimited || model.options.format == .excel {
                TextField(t("NULL 标记（留空不转换）", "NULL Marker (empty = disabled)"), text: $model.options.nullToken)
                Text(t("文本文件只转换未加引号的标记；Excel 按单元格文本匹配。", "Delimited files convert only unquoted markers; Excel matches cell text.")).font(.caption).foregroundStyle(.secondary)
            }
            if model.options.format == .sql {
                Toggle(t("普通字符串使用 MySQL 反斜杠转义", "Use MySQL Backslash Escapes in Plain Strings"), isOn: $model.options.sqlBackslashEscapes)
                Text(t("仅提取同一张表的 INSERT VALUES 字面量；重新映射到当前目标，不执行原始脚本。", "Reads literal INSERT VALUES for one table and maps them to this target. The source script is not executed.")).font(.caption).foregroundStyle(.secondary)
            }
            Stepper(t("预览行数：\(model.options.previewRows)", "Preview rows: \(model.options.previewRows)"), value: $model.options.previewRows, in: 10...200, step: 10)
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).disabled(model.isLoading)
    }

    private var mapping: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t(
                "数据来自所选文件 · 共 \(model.file?.rowCount ?? 0) 行 · 右侧预览前 \(model.preview.count) 行 · 已映射 \(model.mapping.compactMap { $0 }.count) / \(model.mapping.count) 个字段",
                "Data comes from the selected file · \(model.file?.rowCount ?? 0) total rows · showing the first \(model.preview.count) · \(model.mapping.compactMap { $0 }.count) / \(model.mapping.count) columns mapped"
            ))
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                WorkspaceDataImportMappingTable(
                    sourceColumns: model.sourceColumns,
                    targetColumns: model.schema?.writableColumns ?? [],
                    mapping: model.mapping,
                    onChange: { index, value in
                        model.mapping[index] = value
                    }
                )
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                Divider()
                WorkspaceDataImportPreviewTable(rows: model.preview, columns: model.sourceColumns)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var confirmation: some View {
        Form {
            LabeledContent(t("目标表", "Target"), value: model.targetLabel)
            LabeledContent(t("源文件", "File"), value: model.fileURL?.lastPathComponent ?? "")
            LabeledContent(t("待导入行数", "Rows to Import"), value: String(model.file?.rowCount ?? 0))
            LabeledContent(t("导入模式", "Mode"), value: t("追加数据（重复键时报错）", "Append (fail on duplicate keys)"))
            integerField(t("每批行数（1～10000）", "Rows per Batch (1–10000)"), value: $model.batchSize)
            Text(t("导入使用一个事务。任何批次失败或提交前取消都会回滚；不会清空已有数据。", "Uses one transaction. A failed batch or cancellation before commit rolls back the import; existing data is retained.")).foregroundStyle(.secondary)
            if model.safetyLock.isEnabled {
                Label(t("安全锁已开启，请先在主窗口解锁后开始导入。", "Safety Lock is on. Unlock in the main window before importing."), systemImage: "lock.fill").foregroundStyle(.orange)
            }
            DisclosureGroup(t("SQL 示例（预览值可能截断）", "SQL Example (preview values may be truncated)")) {
                Text(model.confirmationSQL).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(t("仅显示首行示例；实际导入使用完整值。", "Shows an example of the first row. Import uses the complete values."))
                    .font(.caption).foregroundStyle(.secondary)
            }

        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }

    private var execution: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.outcome?.message ?? (model.isCancelling ? t("正在停止并回滚…", "Stopping and rolling back…") : t("正在导入…", "Importing…")))
                .font(.title3).textSelection(.enabled)
            ProgressView(value: Double(model.completedRows), total: Double(max(1, model.file?.rowCount ?? 0)))
            Text(t("已处理 \(model.completedRows) / \(model.file?.rowCount ?? 0) 行", "Processed \(model.completedRows) / \(model.file?.rowCount ?? 0) rows")).monospacedDigit()
            if model.isRunning {
                Text(t("提交前处理的行数不代表已保存。取消会等待当前数据库请求返回后回滚。", "Processed rows are not saved until commit. Cancellation waits for the current database request, then rolls back.")).foregroundStyle(.secondary)
            } else if model.outcome?.status == .completed {
                Text(t("可使用主窗口顶部刷新按钮查看导入后的数据。", "Use the main window’s Refresh button to view the imported data.")).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Button(model.step == .execution ? t("关闭", "Close") : t("取消", "Cancel"), action: close)
                .keyboardShortcut(.cancelAction).disabled(model.isRunning)
            Spacer()
            if model.isRunning {
                Button(t("取消导入", "Cancel Import"), action: model.cancel).disabled(model.isCancelling)
            } else if model.step != .execution {
                if model.step != .source { Button(t("上一步", "Back"), action: model.back).disabled(model.isLoading) }
                Button(model.step == .confirmation ? t("开始导入", "Start Import") : t("下一步", "Next"), action: model.next)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.isLoading || (model.step == .confirmation && model.safetyLock.isEnabled))
            }
        }
    }

    private func integerField(_ label: String, value: Binding<Int>) -> some View {
        TextField(label, value: value, format: .number.grouping(.never))
    }
}

@MainActor
struct WorkspaceDataImportMappingTable: NSViewRepresentable {
    let sourceColumns: [WorkspaceDataImportModel.SourceColumn]
    let targetColumns: [WorkspaceDatabaseColumn]
    let mapping: [String?]
    let onChange: @MainActor (Int, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        let tableView = NSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.18)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.headerView = NSTableHeaderView()
        tableView.usesAutomaticRowHeights = false
        context.coordinator.tableView = tableView
        scrollView.documentView = tableView
        update(tableView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? NSTableView else { return }
        update(tableView, coordinator: context.coordinator)
    }

    private func update(_ tableView: NSTableView, coordinator: Coordinator) {
        let structureChanged = coordinator.sourceColumns != sourceColumns || coordinator.targetColumns != targetColumns
        let previousMapping = coordinator.mapping
        coordinator.sourceColumns = sourceColumns
        coordinator.targetColumns = targetColumns
        coordinator.mapping = mapping
        coordinator.onChange = onChange
        if structureChanged {
            coordinator.choices = [("", AppCopy.current.text("跳过此字段", "Skip Column"))]
                + targetColumns.map { ($0.name, "\($0.name) · \($0.type)") }
        }
        let titles = tableView.tableColumns.map(\.title)
        let expected = [
            AppCopy.current.text("源字段", "Source"),
            AppCopy.current.text("目标字段", "Target")
        ]
        if titles != expected {
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }
            let source = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("import-mapping-source"))
            source.title = expected[0]
            source.width = 116
            source.minWidth = 92
            let target = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("import-mapping-target"))
            target.title = expected[1]
            target.width = 178
            target.minWidth = 150
            tableView.addTableColumn(source)
            tableView.addTableColumn(target)
        }
        if structureChanged || titles != expected {
            tableView.reloadData()
        } else if previousMapping != mapping {
            let changed = IndexSet(mapping.indices.filter { !previousMapping.indices.contains($0) || previousMapping[$0] != mapping[$0] })
            tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 1))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var choices: [(String, String)] = []
        var sourceColumns: [WorkspaceDataImportModel.SourceColumn] = []
        var targetColumns: [WorkspaceDatabaseColumn] = []
        var mapping: [String?] = []
        var onChange: (@MainActor (Int, String?) -> Void)?
        weak var tableView: NSTableView?

        func numberOfRows(in tableView: NSTableView) -> Int { sourceColumns.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row >= 0, row < sourceColumns.count else { return nil }
            let sourceIdentifier = NSUserInterfaceItemIdentifier("import-mapping-source-cell")
            let targetIdentifier = NSUserInterfaceItemIdentifier("import-mapping-target-cell")
            if tableColumn.identifier == sourceIdentifierForColumn {
                let cell = (tableView.makeView(withIdentifier: sourceIdentifier, owner: self) as? NSTableCellView)
                    ?? makeSourceCell(identifier: sourceIdentifier)
                cell.textField?.stringValue = sourceColumns[row].name
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: targetIdentifier, owner: self) as? NSTableCellView)
                ?? makeTargetCell(identifier: targetIdentifier)
            guard let popup = cell.subviews.compactMap({ $0 as? WorkspaceDataImportMappingPopUpButton }).first else { return cell }
            popup.tag = row
            let selected = mapping.indices.contains(row) ? (mapping[row] ?? "") : ""
            popup.configure(choices: choices, selected: selected)

            return cell
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let value = sender.selectedItem?.representedObject as? String
            onChange?(sender.tag, value?.isEmpty == true ? nil : value)
        }

        private var sourceIdentifierForColumn: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("import-mapping-source")
        }

        private func makeSourceCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 2
            field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            cell.textField = field
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private func makeTargetCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let popup = WorkspaceDataImportMappingPopUpButton()
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.target = self
            popup.action = #selector(selectionChanged(_:))
            popup.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            cell.addSubview(popup)
            NSLayoutConstraint.activate([
                popup.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                popup.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                popup.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
    }
}

@MainActor
final class WorkspaceDataImportMappingPopUpButton: NSPopUpButton, NSMenuDelegate {
    private var choices: [(String, String)] = []
    private var selectedValue = ""

    func configure(choices: [(String, String)], selected: String) {
        self.choices = choices
        selectedValue = selected
        removeAllItems()
        addItem(withTitle: choices.first(where: { $0.0 == selected })?.1 ?? "—")
        lastItem?.representedObject = selected
        menu?.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        for choice in choices {
            addItem(withTitle: choice.1)
            lastItem?.representedObject = choice.0
            if choice.0 == selectedValue { selectItem(at: numberOfItems - 1) }
        }
    }
}

@MainActor
struct WorkspaceDataImportPreviewTable: NSViewRepresentable {
    let rows: [WorkspaceDataImportModel.PreviewRow]
    let columns: [WorkspaceDataImportModel.SourceColumn]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        let tableView = NSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 34
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.18)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.headerView = NSTableHeaderView()
        tableView.usesAutomaticRowHeights = false
        context.coordinator.tableView = tableView
        scrollView.documentView = tableView
        update(tableView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? NSTableView else { return }
        update(tableView, coordinator: context.coordinator)
    }

    private func update(_ tableView: NSTableView, coordinator: Coordinator) {
        guard coordinator.rows != rows || coordinator.columns != columns else { return }
        coordinator.rows = rows
        coordinator.columns = columns
        coordinator.dataRows = rows.map { row in
            WorkspaceDatabaseDataRow(id: row.id, values: row.cells.map { $0.map(WorkspaceDatabaseDataCell.text) ?? .null })
        }
        let titles = tableView.tableColumns.map(\.title)
        if titles != columns.map(\.name) {
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }
            for (index, column) in columns.enumerated() {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("import-preview-\(index)"))
                tableColumn.title = column.name
                tableColumn.width = 180
                tableColumn.minWidth = 120
                tableColumn.maxWidth = 600
                tableView.addTableColumn(tableColumn)
            }
        }
        coordinator.columnIndexes = Dictionary(uniqueKeysWithValues: tableView.tableColumns.enumerated().map { ($0.element.identifier, columns[$0.offset].index) })
        tableView.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [WorkspaceDataImportModel.PreviewRow] = []
        var columns: [WorkspaceDataImportModel.SourceColumn] = []
        var dataRows: [WorkspaceDatabaseDataRow] = []
        var columnIndexes: [NSUserInterfaceItemIdentifier: Int] = [:]
        weak var tableView: NSTableView?

        func numberOfRows(in tableView: NSTableView) -> Int { dataRows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard dataRows.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("import-preview-row")
            let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? WorkspaceDatabaseDataRowView) ?? WorkspaceDatabaseDataRowView()
            view.identifier = identifier
            view.configure(tableView: tableView, dataRow: dataRows[row], rowIndex: row,
                           columnIndexes: columnIndexes,
                           rowNumberIdentifier: NSUserInterfaceItemIdentifier("import-preview-no-row-number"),
                           cellFont: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                           accessibilityPrefix: "importPreview")
            return view
        }
        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView else { return }
            WorkspaceDatabaseDataRowView.invalidateVisibleRows(in: tableView)
        }
    }
}
