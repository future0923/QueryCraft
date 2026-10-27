import Foundation
import Observation
import QueryCraftMobileCore

/// Captures committed raw values; refreshes behind the sheet cannot change a file.
struct MobileDataExportSnapshot: Sendable {
    let data: MobileGridData
    let name: String
    let scopeDescription: String
    var tableIdentifierParts: [String]? = nil
    var allRowsProvider: WorkspaceDataExportAllRowsProvider? = nil
    var hasBinaryColumns = false
    var allRowsLabel = "全部匹配数据"
    var isQueryCache = false
    var sqlDialect: WorkspaceSQLExportDialect? = .mysql

    var canExport: Bool { !data.rows.isEmpty && !data.columns.isEmpty }
    var hasBinaryValues: Bool {
        hasBinaryColumns || data.cells.contains { row in row.contains { if case .binary = $0 { return true }; return false } }
    }

    func request(options: WorkspaceDataExportOptions) throws -> WorkspaceDataExportRequest {
        var options = options
        if options.format == .sql {
            guard let sqlDialect else { throw WorkspaceDataExportError.unsupportedSQLValue }
            options.sqlDialect = sqlDialect
        }
        if options.scope == .allTableRows {
            guard let provider = allRowsProvider, !data.columns.isEmpty else {
                throw WorkspaceDataExportError.missingColumns
            }
            return .init(columns: data.columns.enumerated().map { .init(name: $0.element, dataIndex: $0.offset) },
                options: options, estimatedRowCount: provider.estimatedRowCount,
                worksheetName: name, source: provider.makeSource())
        }
        guard canExport else { throw WorkspaceDataExportError.missingColumns }
        for row in data.rows.indices {
            for column in data.columns.indices {
                guard (data.cells.indices.contains(row) && data.cells[row].indices.contains(column))
                    || data.rows[row].indices.contains(column) else { throw WorkspaceDataExportError.missingRow }
            }
        }
        let snapshot = WorkspaceDataExportSnapshot(
            allRows: .range(0...(data.rows.count - 1)),
            allColumns: data.columns.enumerated().map { .init(name: $0.element, dataIndex: $0.offset) },
            selectedRows: nil, selectedColumns: nil,
            rowAt: { [data] row in
                guard data.rows.indices.contains(row) else { return nil }
                return .init(id: row, values: data.columns.indices.map { data.cell(row: row, column: $0) })
            }, allRowsSource: nil, selectedRowsSource: nil)
        guard let request = snapshot.request(options: options, worksheetName: name) else {
            throw WorkspaceDataExportError.missingColumns
        }
        return request
    }
}

struct MobileDataExportFile: Identifiable {
    let id = UUID()
    let url: URL
    let options: WorkspaceDataExportOptions
    let rowCount: Int
}

protocol MobileDataExportWriting: Sendable {
    func export(_ request: WorkspaceDataExportRequest, to destination: URL,
                progress: @escaping WorkspaceDataExporter.ProgressHandler) async throws -> Int
}

extension WorkspaceDataExporter: MobileDataExportWriting {}

@MainActor @Observable final class MobileDataExportModel: Identifiable {
    let id = UUID()
    let snapshot: MobileDataExportSnapshot
    var scope = WorkspaceDataExportScope.currentData
    var format = WorkspaceDataExportFormat.xlsx
    var preferences: WorkspaceDataExportPreferences
    var sqlTableName: String
    var worksheetName: String
    private(set) var isExporting = false
    private(set) var completedRows = 0
    private(set) var file: MobileDataExportFile?
    private(set) var message: String?
    private(set) var isBackgrounded = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private let directory: URL
    private let writer: any MobileDataExportWriting

    init(snapshot: MobileDataExportSnapshot, temporaryRoot: URL = FileManager.default.temporaryDirectory,
         writer: any MobileDataExportWriting = WorkspaceDataExporter(), defaults: MobilePreferences = .shared) {
        preferences = defaults.validDataExport
        self.snapshot = snapshot
        self.writer = writer
        sqlTableName = snapshot.tableIdentifierParts?.last ?? ""
        worksheetName = snapshot.name
        directory = temporaryRoot.appending(path: "QueryCraft-export-" + UUID().uuidString, directoryHint: .isDirectory)
    }

    var canPrepare: Bool {
        (scope == .allTableRows ? snapshot.allRowsProvider != nil && !snapshot.data.columns.isEmpty : snapshot.canExport)
            && (format != .sql || snapshot.sqlDialect != nil) && preferences.isValid && !isExporting && !isBackgrounded
            && (format != .sql || !sqlTableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @discardableResult func prepare() -> Task<Void, Never>? {
        guard canPrepare else { return nil }
        cancel()
        let token = UUID(); generation = token
        var options = preferences.options(for: format)
        options.scope = scope
        options.xlsxWorksheetName = worksheetName
        options.sqlTableName = sqlTableName
        if let parts = snapshot.tableIdentifierParts, sqlTableName == parts.last {
            options.sqlTableIdentifierParts = preferences.sqlIncludesDatabaseName ? parts : [sqlTableName]
        } else {
            // A typed query target follows the same dotted-name rule as Mac.
            options.sqlTableIdentifierParts = nil
        }
        let snapshot = snapshot, directory = directory.appending(path: token.uuidString, directoryHint: .isDirectory), writer = writer
        isExporting = true; completedRows = 0; message = nil
        let operation = Task { [weak self] in
            do {
                let request = try snapshot.request(options: options)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let url = directory.appending(path: Self.fileName(snapshot.name) + "." + options.fileExtension)
                let count = try await writer.export(request, to: url) { [weak self] rows in
                    await self?.updateProgress(rows, token: token)
                }
                guard !Task.isCancelled, let self, self.generation == token else {
                    try? FileManager.default.removeItem(at: directory); return
                }
                self.file = .init(url: url, options: options, rowCount: count)
                self.isExporting = false; self.task = nil
            } catch {
                try? FileManager.default.removeItem(at: directory)
                guard let self, self.generation == token else { return }
                self.isExporting = false; self.task = nil
                if !(error is CancellationError) { self.message = MobileConnectionFeedback.reading(error) }
            }
        }
        task = operation
        return operation
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isExporting = false
        file = nil; completedRows = 0; message = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func setBackgrounded(_ backgrounded: Bool) {
        guard isBackgrounded != backgrounded else { return }
        isBackgrounded = backgrounded
        if backgrounded, isExporting {
            cancel()
            message = "导出已暂停。返回后可重新生成文件。"
        }
    }

    func saveFailed(_ error: Error) { message = error.localizedDescription }

    private func updateProgress(_ rows: Int, token: UUID) {
        guard generation == token else { return }
        completedRows = rows
    }

    nonisolated static func fileName(_ name: String) -> String {
        let safe = name.map { "/\\:\0\n\r".contains($0) ? "_" : $0 }
        let value = String(safe.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "." || value == ".." ? "query-result" : value
    }
}
