import SwiftUI

struct WorkspaceElasticsearchConsoleResultView: View {
    let result: WorkspaceElasticsearchConsoleResult
    var canLocateError = false
    var locateError: () -> Void = {}
    @State private var exportController = WorkspaceDataExportController()
    @State private var searchController = WorkspaceGridSearchController()
    @State private var rowInsertEditor = WorkspaceDatabaseDataRowInsertEditorState()
    @State private var selectedRows = IndexSet()
    @State private var preferences = ApplicationPreferences.shared
    @State private var presentationOverride: Presentation?
    @State private var presentedResultID: UUID?
    @State private var hasOpenedJSON = false
    @State private var showsDetails = false

    private enum Presentation { case table, json }
    private var hasTable: Bool {
        if case .grid = result.output { return true }
        return false
    }
    private var presentation: Presentation {
        guard hasTable else { return .json }
        if presentedResultID == result.id, let presentationOverride { return presentationOverride }
        return result.details?.prefersJSON == true ? .json : .table
    }
    private var fullResponse: String? {
        if let details = result.details { return details.fullResponse }
        if case .json(let text) = result.output { return text }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker(
                    AppCopy.current.text("结果显示", "Result Display"),
                    selection: Binding(
                        get: { presentation },
                        set: {
                            if presentation == .json || $0 == .json { hasOpenedJSON = true }
                            presentationOverride = $0
                            presentedResultID = result.id
                        }
                    )
                ) {
                    Text(AppCopy.current.text("表格", "Table")).tag(Presentation.table).disabled(!hasTable)
                    Text(AppCopy.current.text("完整 JSON", "Full JSON")).tag(Presentation.json).disabled(
                        fullResponse == nil)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("elasticsearchResultPresentation")
                if let summary = result.details?.summary(copy: .current), !summary.isEmpty {
                    Text(summary).lineLimit(1).truncationMode(.tail).help(summary)
                }
                Spacer(minLength: 0)
                Button(AppCopy.current.text("详情", "Details")) { showsDetails = true }
                    .disabled(result.details == nil)
                    .popover(isPresented: $showsDetails) {
                        if let details = result.details {
                            WorkspaceElasticsearchResponseDetailsView(
                                details: details,
                                canLocateError: canLocateError,
                                locateError: {
                                    showsDetails = false
                                    locateError()
                                })
                        }
                    }
            }
            .font(.callout).padding(.horizontal, 8).frame(height: 36)
            Divider()
            ZStack {
                if case .grid(let page) = result.output {
                    WorkspaceDatabaseDataTable(
                        page: page,
                        isFetching: false,
                        usesAlternatingRows: preferences.usesAlternatingTableRows,
                        nullDisplayText: preferences.tableNullDisplayStyle.displayText,
                        emptyStringDisplayText:
                            preferences.tableEmptyStringDisplayStyle.displayText,
                        copyIncludesColumnNames: preferences.copyIncludesColumnNames,
                        cellFont: preferences.dataGridFont(),
                        exportController: exportController,
                        searchController: searchController,
                        exportAllRowsProvider: nil,
                        exportFileName: "elasticsearch-response",
                        sortData: { _ in },
                        prepareCellEdit: nil,
                        prepareCellEditAsync: nil,
                        updateCellEdit: { _, _ in },
                        databaseColumns: [],
                        pendingLoadedUpdates: [],
                        rowInsertEditor: rowInsertEditor,
                        updateRowInsertDraft: { _, _, _ in },
                        submitRowInsert: {},
                        cancelRowInsert: {},
                        pendingDeleteRowIndexes: [],
                        selectedRowIndexes: selectedRows,
                        rowActionKind: .tableRow,
                        addRow: nil,
                        duplicateRow: nil,
                        deleteRows: nil,
                        pasteRows: nil,
                        selectRowsForActions: { selectedRows = $0 }
                    )
                    .opacity(presentation == .table ? 1 : 0)
                    .allowsHitTesting(presentation == .table)
                    .accessibilityHidden(presentation != .table)
                }
                // Mount JSON lazily, then retain both panes so switching never
                // rebuilds the grid or loses its horizontal viewport/selection.
                if let json = fullResponse, presentation == .json || hasOpenedJSON {
                    WorkspaceReadOnlyTextView(
                        text: json,
                        usesMonospacedFont: true,
                        accessibilityLabel: AppCopy.current.text(
                            "Elasticsearch JSON 响应",
                            "Elasticsearch JSON response"
                        ),
                        showsBorder: false,
                        presentation: .automaticJSON
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(presentation == .json ? 1 : 0)
                    .allowsHitTesting(presentation == .json)
                    .accessibilityHidden(presentation != .json)
                }
                if result.output == nil {
                    ContentUnavailableView {
                        Label(
                            AppCopy.current.text("请求失败", "Request Failed"),
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text(result.errorMessage ?? "")
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text(result.requestSummary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if result.output != nil, let message = result.errorMessage {
                    Text(message).lineLimit(1).help(message).textSelection(.enabled)
                        .foregroundStyle(result.details?.failureMessage != nil ? Color.red : Color.secondary)
                }
                if result.details?.diagnostics.contains(where: { $0.documentRange != nil }) == true {
                    Button(AppCopy.current.text("定位错误", "Locate Error"), action: locateError)
                        .disabled(!canLocateError)
                        .help(
                            canLocateError
                                ? AppCopy.current.text("跳到请求中的错误位置", "Go to the error in the request")
                                : AppCopy.current.text(
                                    "请求已修改，请重新执行后定位。",
                                    "The request has changed. Run it again before locating the error."))
                }
                if let statusCode = result.statusCode {
                    Text("HTTP \(statusCode)")
                }
                Text(result.elapsedSeconds, format: .number.precision(.fractionLength(3)))
                    + Text(" s")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
        .onChange(of: result.id) { _, _ in
            presentationOverride = nil
            presentedResultID = nil
            hasOpenedJSON = false
            showsDetails = false
        }
    }
}
