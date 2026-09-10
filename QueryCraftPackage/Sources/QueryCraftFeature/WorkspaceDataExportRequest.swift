import Foundation
import UniformTypeIdentifiers

enum WorkspaceDataExportScope: String, CaseIterable, Identifiable, Sendable {
    case selection
    case currentData
    case allTableRows

    var id: Self { self }
}

enum WorkspaceDataExportNullStyle: String, CaseIterable, Identifiable, Sendable {
    case literal
    case empty

    var id: Self { self }

    var text: String {
        switch self {
        case .literal:
            "NULL"
        case .empty:
            ""
        }
    }
}

enum WorkspaceCSVDelimiter: String, CaseIterable, Identifiable, Sendable {
    case comma
    case tab
    case semicolon
    case pipe

    var id: Self { self }

    var character: Character {
        switch self {
        case .comma: ","
        case .tab: "\t"
        case .semicolon: ";"
        case .pipe: "|"
        }
    }
}

enum WorkspaceCSVLineEnding: String, CaseIterable, Identifiable, Sendable {
    case crlf
    case lf

    var id: Self { self }

    var text: String {
        switch self {
        case .crlf: "\r\n"
        case .lf: "\n"
        }
    }
}

enum WorkspaceCSVQuotePolicy: String, CaseIterable, Identifiable, Sendable {
    case asNeeded
    case allText

    var id: Self { self }
}

enum WorkspaceJSONLayout: String, CaseIterable, Identifiable, Sendable {
    case tabular
    case objects
    case lines

    var id: Self { self }
}

enum WorkspaceSQLConflictStrategy: String, CaseIterable, Identifiable,
    Sendable
{
    case insert
    case ignore
    case replace

    var id: Self { self }
}

struct WorkspaceDataExportOptions: Sendable {
    var format = WorkspaceDataExportFormat.xlsx
    var scope = WorkspaceDataExportScope.currentData
    var includesColumnNames = true
    var nullStyle = WorkspaceDataExportNullStyle.literal

    var csvIncludesUTF8BOM = true
    var csvDelimiter = WorkspaceCSVDelimiter.comma
    var csvLineEnding = WorkspaceCSVLineEnding.crlf
    var csvQuotePolicy = WorkspaceCSVQuotePolicy.asNeeded
    var sanitizesSpreadsheetFormulas = true

    var jsonLayout = WorkspaceJSONLayout.tabular
    var prettyPrintsJSON = true

    var xlsxWorksheetName = ""
    var xlsxFreezesHeader = true
    var xlsxAddsAutoFilter = true

    var sqlTableName = ""
    var sqlInsertBatchSize = 1_000
    var sqlWrapsInTransaction = true
    var sqlConflictStrategy = WorkspaceSQLConflictStrategy.insert

    var fileExtension: String {
        if format == .json, jsonLayout == .lines {
            return "jsonl"
        }
        return format.fileExtension
    }

    var contentType: UTType {
        if format == .json, jsonLayout == .lines {
            return UTType(filenameExtension: fileExtension) ?? .plainText
        }
        return format.contentType
    }
}

struct WorkspaceDataExportSnapshot: Sendable {
    let allRows: WorkspaceGridCopyRows
    let allColumns: [WorkspaceGridCopyColumn]
    let selectedRows: WorkspaceGridCopyRows?
    let selectedColumns: [WorkspaceGridCopyColumn]?
    let rowAt: @Sendable (Int) -> WorkspaceDatabaseDataRow?
    let allRowsSource: (any WorkspaceDataExportRowSource)?
    let selectedRowsSource: (any WorkspaceDataExportRowSource)?

    var hasSelection: Bool {
        selectedRows?.count ?? 0 > 0
            && !(selectedColumns?.isEmpty ?? true)
    }

    func request(
        options: WorkspaceDataExportOptions,
        worksheetName: String
    )
        -> WorkspaceDataExportRequest?
    {
        let rows: WorkspaceGridCopyRows
        let columns: [WorkspaceGridCopyColumn]
        let preparedSource: (any WorkspaceDataExportRowSource)?
        switch options.scope {
        case .selection:
            guard
                let selectedRows,
                let selectedColumns,
                !selectedColumns.isEmpty
            else {
                return nil
            }
            rows = selectedRows
            columns = selectedColumns
            preparedSource = selectedRowsSource
        case .currentData:
            rows = allRows
            columns = allColumns
            preparedSource = allRowsSource
        case .allTableRows:
            return nil
        }
        guard rows.count > 0, !columns.isEmpty else { return nil }
        return WorkspaceDataExportRequest(
            columns: columns,
            options: options,
            estimatedRowCount: rows.count,
            worksheetName: worksheetName,
            source: preparedSource
                ?? WorkspaceSnapshotDataExportRowSource(
                    rows: rows,
                    rowAt: rowAt
                )
        )
    }
}

struct WorkspaceDataExportRequest: Sendable {
    let columns: [WorkspaceGridCopyColumn]
    let options: WorkspaceDataExportOptions
    let estimatedRowCount: Int?
    let worksheetName: String
    let source: any WorkspaceDataExportRowSource
}

protocol WorkspaceDataExportRowSource: Sendable {
    func nextBatch() async throws -> [WorkspaceDatabaseDataRow]?
    func finish() async
}

extension WorkspaceDataExportRowSource {
    func finish() async {}
}

actor WorkspaceSnapshotDataExportRowSource: WorkspaceDataExportRowSource {
    private static let batchSize = 5_000

    private let rows: WorkspaceGridCopyRows
    private let rowAt: @Sendable (Int) -> WorkspaceDatabaseDataRow?
    private var nextRowIndex: Int?

    init(
        rows: WorkspaceGridCopyRows,
        rowAt: @escaping @Sendable (Int) -> WorkspaceDatabaseDataRow?
    ) {
        self.rows = rows
        self.rowAt = rowAt
        nextRowIndex = rows.first
    }

    func nextBatch() throws -> [WorkspaceDatabaseDataRow]? {
        try Task.checkCancellation()
        guard var rowIndex = nextRowIndex else { return nil }
        var batch: [WorkspaceDatabaseDataRow] = []
        batch.reserveCapacity(min(Self.batchSize, rows.count))
        while batch.count < Self.batchSize {
            guard let row = rowAt(rowIndex) else {
                throw WorkspaceDataExportError.missingRow
            }
            batch.append(row)
            guard let followingIndex = followingIndex(after: rowIndex) else {
                nextRowIndex = nil
                return batch
            }
            rowIndex = followingIndex
        }
        nextRowIndex = rowIndex
        return batch
    }

    private func followingIndex(after index: Int) -> Int? {
        switch rows {
        case let .range(range):
            guard index < range.upperBound else { return nil }
            return index + 1
        case let .indexes(indexes):
            return indexes.integerGreaterThan(index)
        }
    }
}

struct WorkspaceDataExportAllRowsProvider: Sendable {
    let estimatedRowCount: Int?
    let makeSource: @Sendable () -> any WorkspaceDataExportRowSource
}
