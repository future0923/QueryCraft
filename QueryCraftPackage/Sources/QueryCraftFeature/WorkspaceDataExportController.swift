import AppKit
import SwiftUI

enum WorkspaceDataExportSourceKind: Sendable {
    case queryResult
    case tablePage
}

@MainActor
@Observable
final class WorkspaceDataExportController {
    var isPresentingOptions = false
    var options = WorkspaceDataExportOptions()
    var showsError = false
    private(set) var errorMessage = ""
    private(set) var hasSelection = false
    private(set) var totalRowCount = 0
    private(set) var selectedRowCount = 0
    private(set) var allTableRowCount: Int?

    @ObservationIgnored private weak var tableView:
        WorkspaceDirectDrawTableView?
    @ObservationIgnored private var pendingSnapshot:
        WorkspaceDataExportSnapshot?
    @ObservationIgnored private var sourceKind =
        WorkspaceDataExportSourceKind.queryResult
    @ObservationIgnored private var allRowsProvider:
        WorkspaceDataExportAllRowsProvider?
    @ObservationIgnored private var suggestedFileName = "query-result"
    @ObservationIgnored private var knownSQLTableName: String?

    func attach(
        tableView: WorkspaceDirectDrawTableView,
        sourceKind: WorkspaceDataExportSourceKind,
        suggestedFileName: String,
        allRowsProvider: WorkspaceDataExportAllRowsProvider? = nil
    ) {
        self.tableView = tableView
        self.sourceKind = sourceKind
        self.suggestedFileName = suggestedFileName
        knownSQLTableName = switch sourceKind {
        case .queryResult:
            nil
        case .tablePage:
            suggestedFileName
        }
        self.allRowsProvider = allRowsProvider
        allTableRowCount = allRowsProvider?.estimatedRowCount
        tableView.dataExportController = self
    }

    func updateAllRowsProvider(
        _ provider: WorkspaceDataExportAllRowsProvider?,
        suggestedFileName: String
    ) {
        allRowsProvider = provider
        allTableRowCount = provider?.estimatedRowCount
        self.suggestedFileName = suggestedFileName
        if case .tablePage = sourceKind {
            knownSQLTableName = suggestedFileName
        }
    }

    func presentOptions(
        defaultScope: WorkspaceDataExportScope = .currentData
    ) {
        guard let snapshot = tableView?.dataExportSnapshot() else { return }
        pendingSnapshot = snapshot
        hasSelection = snapshot.hasSelection
        totalRowCount = snapshot.allRows.count
        selectedRowCount = snapshot.selectedRows?.count ?? 0
        options.scope = defaultScope == .selection && snapshot.hasSelection
            ? .selection
            : .currentData
        if options.sqlTableName.isEmpty, let knownSQLTableName {
            options.sqlTableName = knownSQLTableName
        }
        isPresentingOptions = true
    }

    func cancelOptions() {
        isPresentingOptions = false
        pendingSnapshot = nil
    }

    func chooseDestinationAndExport() {
        guard pendingSnapshot != nil else {
            showPreparationError()
            return
        }
        isPresentingOptions = false

        let selectedOptions = options
        let panel = NSSavePanel()
        panel.title = AppCopy.current.text("导出数据", "Export Data")
        panel.prompt = AppCopy.current.text("导出", "Export")
        panel.message = AppCopy.current.text(
            "选择导出文件的名称和位置。",
            "Choose a name and location for the export file."
        )
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [selectedOptions.contentType]
        panel.isExtensionHidden = false
        panel.nameFieldStringValue =
            "\(suggestedFileName).\(selectedOptions.fileExtension)"
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else {
                self?.pendingSnapshot = nil
                return
            }
            self?.startExport(
                options: selectedOptions,
                to: destination
            )
        }
    }

    var allRowsTitle: String {
        switch sourceKind {
        case .queryResult:
            AppCopy.current.text(
                "当前结果（\(totalRowCount) 行）",
                "Current Result (\(totalRowCount) rows)"
            )
        case .tablePage:
            AppCopy.current.text(
                "当前页（\(totalRowCount) 行）",
                "Current Page (\(totalRowCount) rows)"
            )
        }
    }

    var allTableRowsTitle: String {
        if let allTableRowCount {
            return AppCopy.current.text(
                "整张表（\(allTableRowCount) 行）",
                "Entire Table (\(allTableRowCount) rows)"
            )
        }
        return AppCopy.current.text("整张表", "Entire Table")
    }

    var supportsAllTableRows: Bool {
        allRowsProvider != nil
    }

    var hasMultipleExportScopes: Bool {
        supportsAllTableRows || hasSelection
    }

    var selectionTitle: String {
        AppCopy.current.text(
            "所选内容（\(selectedRowCount) 行）",
            "Selection (\(selectedRowCount) rows)"
        )
    }

    private func startExport(
        options: WorkspaceDataExportOptions,
        to destination: URL
    ) {
        guard let pendingSnapshot else {
            showPreparationError()
            return
        }
        let request: WorkspaceDataExportRequest?
        if options.scope == .allTableRows {
            if let allRowsProvider {
                request = WorkspaceDataExportRequest(
                    columns: pendingSnapshot.allColumns,
                    options: options,
                    estimatedRowCount: allRowsProvider.estimatedRowCount,
                    worksheetName: suggestedFileName,
                    source: allRowsProvider.makeSource()
                )
            } else {
                request = nil
            }
        } else {
            request = pendingSnapshot.request(
                options: options,
                worksheetName: suggestedFileName
            )
        }
        guard let request else {
            showPreparationError()
            return
        }
        self.pendingSnapshot = nil
        WorkspaceDataExportJobManager.shared.enqueue(
            request: request,
            destination: destination
        )
    }

    private func showPreparationError() {
        pendingSnapshot = nil
        errorMessage = AppCopy.current.text(
            "无法准备所选的导出范围，请重新打开导出。",
            "The selected export scope could not be prepared. Open Export again."
        )
        showsError = true
    }
}
