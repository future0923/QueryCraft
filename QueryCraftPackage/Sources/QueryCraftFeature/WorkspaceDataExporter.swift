import Foundation
import zlib

enum WorkspaceDataExportError: LocalizedError {
    case missingRow
    case missingSQLTableName
    case unableToCreateFile
    case unableToCompressFile
    case fileTooLarge
    case tooManyWorksheets

    var errorDescription: String? {
        switch self {
        case .missingRow:
            AppCopy.current.text(
                "导出期间结果数据发生了变化。",
                "The result data changed during export."
            )
        case .missingSQLTableName:
            AppCopy.current.text(
                "SQL 导出需要表名。",
                "SQL export requires a table name."
            )
        case .unableToCreateFile:
            AppCopy.current.text(
                "无法创建导出文件。",
                "The export file could not be created."
            )
        case .unableToCompressFile:
            AppCopy.current.text(
                "无法压缩 Excel 导出文件。",
                "The Excel export file could not be compressed."
            )
        case .fileTooLarge:
            AppCopy.current.text(
                "导出文件超过了支持的大小。",
                "The export file exceeds the supported size."
            )
        case .tooManyWorksheets:
            AppCopy.current.text(
                "Excel 工作表数量超过了支持的上限。",
                "The Excel workbook exceeds the supported worksheet limit."
            )
        }
    }
}

actor WorkspaceDataExporter {
    typealias ProgressHandler =
        @Sendable (_ completedRows: Int) async -> Void

    func export(
        _ request: WorkspaceDataExportRequest,
        to destination: URL,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> Int {
        let fileManager = FileManager.default
        let replacementDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )
        let temporaryURL = replacementDirectory.appending(
            path: "QueryCraft-\(UUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw WorkspaceDataExportError.unableToCreateFile
        }

        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: temporaryURL)
            }
            try? fileManager.removeItem(at: replacementDirectory)
        }

        let fileHandle = try FileHandle(forWritingTo: temporaryURL)
        do {
            let rowCount: Int
            switch request.options.format {
            case .xlsx:
                rowCount = try await WorkspaceXLSXExporter.write(
                    request,
                    to: fileHandle,
                    progress: progress
                )
            case .csv:
                rowCount = try await WorkspaceCSVExporter.write(
                    request,
                    to: fileHandle,
                    progress: progress
                )
            case .json:
                rowCount = try await WorkspaceJSONExporter.write(
                    request,
                    to: fileHandle,
                    progress: progress
                )
            case .sql:
                rowCount = try await WorkspaceSQLExporter.write(
                    request,
                    to: fileHandle,
                    progress: progress
                )
            }
            await request.source.finish()
            try Task.checkCancellation()
            try fileHandle.close()
            try commit(temporaryURL, to: destination)
            committed = true
            return rowCount
        } catch {
            await request.source.finish()
            try? fileHandle.close()
            throw error
        }
    }

    private func commit(
        _ temporaryURL: URL,
        to destination: URL
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporaryURL
            )
        } else {
            try fileManager.moveItem(
                at: temporaryURL,
                to: destination
            )
        }
    }
}

private struct WorkspaceBufferedFileWriter {
    private static let flushThreshold = 256 * 1_024

    private let fileHandle: FileHandle
    private var buffer = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        buffer.reserveCapacity(Self.flushThreshold)
    }

    mutating func write(_ data: Data) throws {
        if buffer.isEmpty, data.count >= Self.flushThreshold {
            try fileHandle.write(contentsOf: data)
            return
        }
        buffer.append(data)
        if buffer.count >= Self.flushThreshold {
            try flush()
        }
    }

    mutating func writeUTF8(_ string: String) throws {
        try write(Data(string.utf8))
    }

    mutating func finish() throws {
        try flush()
    }

    private mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        try fileHandle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

private struct WorkspaceDataExportProgressReporter {
    private static let minimumInterval = Duration.milliseconds(200)

    private let handler: WorkspaceDataExporter.ProgressHandler
    private var lastUpdate = ContinuousClock.now

    init(handler: @escaping WorkspaceDataExporter.ProgressHandler) {
        self.handler = handler
    }

    mutating func reportIfNeeded(
        _ completedRows: Int,
        force: Bool = false
    ) async {
        let now = ContinuousClock.now
        guard force || lastUpdate.duration(to: now) >= Self.minimumInterval
        else {
            return
        }
        lastUpdate = now
        await handler(completedRows)
    }
}

private enum WorkspaceCSVExporter {
    static func write(
        _ request: WorkspaceDataExportRequest,
        to fileHandle: FileHandle,
        progress: @escaping WorkspaceDataExporter.ProgressHandler
    ) async throws -> Int {
        var writer = WorkspaceBufferedFileWriter(fileHandle: fileHandle)
        var progressReporter = WorkspaceDataExportProgressReporter(
            handler: progress
        )
        if request.options.csvIncludesUTF8BOM {
            try writer.write(Data([0xEF, 0xBB, 0xBF]))
        }
        if request.options.includesColumnNames {
            try writeLine(
                request.columns.map(\.name),
                options: request.options,
                forceQuotedEmptyStrings: false,
                to: &writer
            )
        }

        var rowCount = 0
        var nextBatch = try await request.source.nextBatch()
        while let batch = nextBatch {
            async let prefetchedBatch = request.source.nextBatch()
            try Task.checkCancellation()
            for (batchIndex, row) in batch.enumerated() {
                if batchIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                try writeRow(
                    row,
                    columns: request.columns,
                    nullStyle: request.options.nullStyle,
                    options: request.options,
                    to: &writer
                )
                rowCount += 1
                if rowCount.isMultiple(of: 128) {
                    await progressReporter.reportIfNeeded(rowCount)
                }
            }
            nextBatch = try await prefetchedBatch
            await Task.yield()
        }
        await progressReporter.reportIfNeeded(rowCount, force: true)
        try writer.finish()
        return rowCount
    }

    private static func writeLine(
        _ fields: [String],
        options: WorkspaceDataExportOptions,
        forceQuotedEmptyStrings: Bool = false,
        to writer: inout WorkspaceBufferedFileWriter
    ) throws {
        var line = ""
        line.reserveCapacity(max(64, fields.count * 16))
        for (offset, field) in fields.enumerated() {
            if offset > 0 {
                line.append(options.csvDelimiter.character)
            }
            line.append(
                encode(
                    field,
                    options: options,
                    forceQuotes: forceQuotedEmptyStrings && field.isEmpty
                )
            )
        }
        line.append(options.csvLineEnding.text)
        try writer.writeUTF8(line)
    }

    private static func writeRow(
        _ row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceGridCopyColumn],
        nullStyle: WorkspaceDataExportNullStyle,
        options: WorkspaceDataExportOptions,
        to writer: inout WorkspaceBufferedFileWriter
    ) throws {
        var line = ""
        line.reserveCapacity(max(64, columns.count * 16))
        for (offset, column) in columns.enumerated() {
            if offset > 0 {
                line.append(options.csvDelimiter.character)
            }
            let value: String
            let forceQuotes: Bool
            switch row.value(at: column.dataIndex) {
            case .null:
                value = nullStyle.text
                forceQuotes = false
            case let .text(text):
                value = text
                forceQuotes = text.isEmpty
            case let .binary(byteCount, _):
                value = "<BINARY \(byteCount) bytes>"
                forceQuotes = false
            }
            line.append(
                encode(
                    value,
                    options: options,
                    forceQuotes: forceQuotes
                )
            )
        }
        line.append(options.csvLineEnding.text)
        try writer.writeUTF8(line)
    }

    private static func encode(
        _ value: String,
        options: WorkspaceDataExportOptions,
        forceQuotes: Bool
    ) -> String {
        var value = value
        if options.sanitizesSpreadsheetFormulas,
           let first = value.first,
           ([Character]("=+-@")).contains(first)
        {
            value.insert("'", at: value.startIndex)
        }
        let requiresQuotes = forceQuotes
            || options.csvQuotePolicy == .allText
            || value.contains(options.csvDelimiter.character)
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
        guard requiresQuotes else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private enum WorkspaceJSONExporter {
    static func write(
        _ request: WorkspaceDataExportRequest,
        to fileHandle: FileHandle,
        progress: @escaping WorkspaceDataExporter.ProgressHandler
    ) async throws -> Int {
        switch request.options.jsonLayout {
        case .tabular:
            try await writeTabular(request, to: fileHandle, progress: progress)
        case .objects:
            try await writeObjects(request, to: fileHandle, progress: progress)
        case .lines:
            try await writeLines(request, to: fileHandle, progress: progress)
        }
    }

    private static func writeTabular(
        _ request: WorkspaceDataExportRequest,
        to fileHandle: FileHandle,
        progress: @escaping WorkspaceDataExporter.ProgressHandler
    ) async throws -> Int {
        var writer = WorkspaceBufferedFileWriter(fileHandle: fileHandle)
        var progressReporter = WorkspaceDataExportProgressReporter(
            handler: progress
        )
        let pretty = request.options.prettyPrintsJSON
        let newline = pretty ? "\n" : ""
        let indent = pretty ? "  " : ""
        try write("{\(newline)", to: &writer)
        try write(
            "\(indent)\"columns\":\(pretty ? " " : "")",
            to: &writer
        )
        try writeJSONObject(request.columns.map(\.name), to: &writer)
        try write(
            ",\(newline)\(indent)\"rows\":\(pretty ? " " : "")[",
            to: &writer
        )

        var rowCount = 0
        var nextBatch = try await request.source.nextBatch()
        while let batch = nextBatch {
            async let prefetchedBatch = request.source.nextBatch()
            try Task.checkCancellation()
            for (batchIndex, row) in batch.enumerated() {
                if batchIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                if rowCount > 0 {
                    try write(",", to: &writer)
                }
                if pretty {
                    try write("\n\(indent)\(indent)", to: &writer)
                }
                let values: [Any] = request.columns.map { column in
                    switch row.value(at: column.dataIndex) {
                    case .null:
                        NSNull()
                    case let .text(value):
                        value
                    case let .binary(byteCount, _):
                        ["binaryByteCount": byteCount]
                    }
                }
                try writeJSONObject(values, to: &writer)
                rowCount += 1
                if rowCount.isMultiple(of: 128) {
                    await progressReporter.reportIfNeeded(rowCount)
                }
            }
            nextBatch = try await prefetchedBatch
            await Task.yield()
        }
        await progressReporter.reportIfNeeded(rowCount, force: true)
        if pretty, rowCount > 0 {
            try write("\n\(indent)", to: &writer)
        }
        try write("]\(newline)}", to: &writer)
        try writer.finish()
        return rowCount
    }

    private static func writeObjects(
        _ request: WorkspaceDataExportRequest,
        to fileHandle: FileHandle,
        progress: @escaping WorkspaceDataExporter.ProgressHandler
    ) async throws -> Int {
        var writer = WorkspaceBufferedFileWriter(fileHandle: fileHandle)
        var progressReporter = WorkspaceDataExportProgressReporter(
            handler: progress
        )
        let pretty = request.options.prettyPrintsJSON
        let names = uniqueColumnNames(request.columns.map(\.name))
        try writer.writeUTF8("[")
        var rowCount = 0
        var nextBatch = try await request.source.nextBatch()
        while let batch = nextBatch {
            async let prefetchedBatch = request.source.nextBatch()
            try Task.checkCancellation()
            for (batchIndex, row) in batch.enumerated() {
                if batchIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                if rowCount > 0 {
                    try writer.writeUTF8(",")
                }
                if pretty {
                    try writer.writeUTF8("\n  ")
                }
                let object = Dictionary(
                    uniqueKeysWithValues: zip(
                        names,
                        values(for: row, columns: request.columns)
                    )
                )
                let options: JSONSerialization.WritingOptions =
                    pretty ? [.sortedKeys] : []
                try writer.write(
                    JSONSerialization.data(
                        withJSONObject: object,
                        options: options
                    )
                )
                rowCount += 1
                if rowCount.isMultiple(of: 128) {
                    await progressReporter.reportIfNeeded(rowCount)
                }
            }
            nextBatch = try await prefetchedBatch
            await Task.yield()
        }
        await progressReporter.reportIfNeeded(rowCount, force: true)
        if pretty, rowCount > 0 {
            try writer.writeUTF8("\n")
        }
        try writer.writeUTF8("]")
        try writer.finish()
        return rowCount
    }

    private static func writeLines(
        _ request: WorkspaceDataExportRequest,
        to fileHandle: FileHandle,
        progress: @escaping WorkspaceDataExporter.ProgressHandler
    ) async throws -> Int {
        var writer = WorkspaceBufferedFileWriter(fileHandle: fileHandle)
        var progressReporter = WorkspaceDataExportProgressReporter(
            handler: progress
        )
        let names = uniqueColumnNames(request.columns.map(\.name))
        var rowCount = 0
        var nextBatch = try await request.source.nextBatch()
        while let batch = nextBatch {
            async let prefetchedBatch = request.source.nextBatch()
            try Task.checkCancellation()
            for (batchIndex, row) in batch.enumerated() {
                if batchIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                let object = Dictionary(
                    uniqueKeysWithValues: zip(
                        names,
                        values(for: row, columns: request.columns)
                    )
                )
                try writer.write(
                    JSONSerialization.data(withJSONObject: object)
                )
                try writer.writeUTF8("\n")
                rowCount += 1
                if rowCount.isMultiple(of: 128) {
                    await progressReporter.reportIfNeeded(rowCount)
                }
            }
            nextBatch = try await prefetchedBatch
            await Task.yield()
        }
        await progressReporter.reportIfNeeded(rowCount, force: true)
        try writer.finish()
        return rowCount
    }

    private static func uniqueColumnNames(_ names: [String]) -> [String] {
        var counts: [String: Int] = [:]
        return names.map { name in
            let count = (counts[name] ?? 0) + 1
            counts[name] = count
            return count == 1 ? name : "\(name)_\(count)"
        }
    }

    private static func values(
        for row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceGridCopyColumn]
    ) -> [Any] {
        columns.map { column in
            switch row.value(at: column.dataIndex) {
            case .null:
                NSNull()
            case let .text(value):
                value
            case let .binary(byteCount, _):
                ["binaryByteCount": byteCount]
            }
        }
    }

    private static func writeJSONObject(
        _ object: Any,
        to writer: inout WorkspaceBufferedFileWriter
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try writer.write(data)
    }

    private static func write(
        _ value: String,
        to writer: inout WorkspaceBufferedFileWriter
    ) throws {
        try writer.writeUTF8(value)
    }
}

private enum WorkspaceSQLExporter {
    static func write(
        _ request: WorkspaceDataExportRequest,
        to fileHandle: FileHandle,
        progress: @escaping WorkspaceDataExporter.ProgressHandler
    ) async throws -> Int {
        var writer = WorkspaceBufferedFileWriter(fileHandle: fileHandle)
        var progressReporter = WorkspaceDataExportProgressReporter(
            handler: progress
        )
        let options = request.options
        let rawTableName = options.sqlTableName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !rawTableName.isEmpty else {
            throw WorkspaceDataExportError.missingSQLTableName
        }
        let tableName = quotedIdentifier(rawTableName)
        let columns = request.columns.map {
            quotedIdentifier($0.name)
        }.joined(separator: ", ")
        let statementPrefix: String
        switch options.sqlConflictStrategy {
        case .insert:
            statementPrefix = "INSERT INTO"
        case .ignore:
            statementPrefix = "INSERT IGNORE INTO"
        case .replace:
            statementPrefix = "REPLACE INTO"
        }
        if options.sqlWrapsInTransaction {
            try writer.writeUTF8("START TRANSACTION;\n")
        }

        var rowCount = 0
        var rowsInStatement = 0
        let batchSize = max(1, options.sqlInsertBatchSize)
        var nextBatch = try await request.source.nextBatch()
        while let batch = nextBatch {
            async let prefetchedBatch = request.source.nextBatch()
            try Task.checkCancellation()
            for (batchIndex, row) in batch.enumerated() {
                if batchIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                if rowsInStatement == 0 {
                    try writer.writeUTF8(
                        "\(statementPrefix) \(tableName) (\(columns)) VALUES\n"
                    )
                } else {
                    try writer.writeUTF8(",\n")
                }
                try writer.writeUTF8(
                    "  (\(encodedValues(row, columns: request.columns)))"
                )
                rowsInStatement += 1
                rowCount += 1
                if rowsInStatement == batchSize {
                    try writer.writeUTF8(";\n")
                    rowsInStatement = 0
                }
                if rowCount.isMultiple(of: 128) {
                    await progressReporter.reportIfNeeded(rowCount)
                }
            }
            nextBatch = try await prefetchedBatch
            await Task.yield()
        }
        await progressReporter.reportIfNeeded(rowCount, force: true)
        if rowsInStatement > 0 {
            try writer.writeUTF8(";\n")
        }
        if options.sqlWrapsInTransaction {
            try writer.writeUTF8("COMMIT;\n")
        }
        try writer.finish()
        return rowCount
    }

    private static func encodedValues(
        _ row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceGridCopyColumn]
    ) -> String {
        columns.map { column in
            switch row.value(at: column.dataIndex) {
            case .null:
                "NULL"
            case let .text(value):
                "'\(value.replacingOccurrences(of: "'", with: "''"))'"
            case let .binary(byteCount, _):
                "'<BINARY \(byteCount) bytes>'"
            }
        }.joined(separator: ", ")
    }

    private static func quotedIdentifier(_ value: String) -> String {
        value.split(separator: ".", omittingEmptySubsequences: false)
            .map { "`\($0.replacingOccurrences(of: "`", with: "``"))`" }
            .joined(separator: ".")
    }
}

private enum WorkspaceXLSXExporter {
    private static let maximumRowsPerSheet = 1_048_576

    static func write(
        _ request: WorkspaceDataExportRequest,
        to fileHandle: FileHandle,
        progress: @escaping WorkspaceDataExporter.ProgressHandler
    ) async throws -> Int {
        var archive = WorkspaceStreamingZIPWriter(fileHandle: fileHandle)
        var progressReporter = WorkspaceDataExportProgressReporter(
            handler: progress
        )
        var sheetNames: [String] = []
        var sheetNumber = 0
        var sheetRowCount = 0
        var totalRowCount = 0
        var worksheetEntry: WorkspaceStreamingZIPWriter.Entry?
        let columnReferences = request.columns.indices.map(columnLetters)

        func beginSheet() throws {
            sheetNumber += 1
            let sheetName = uniqueSheetName(
                baseName: request.options.xlsxWorksheetName.isEmpty
                    ? request.worksheetName
                    : request.options.xlsxWorksheetName,
                number: sheetNumber,
                existingNames: sheetNames
            )
            sheetNames.append(sheetName)
            worksheetEntry = try archive.beginEntry(
                path: "xl/worksheets/sheet\(sheetNumber).xml"
            )
            try archive.write(
                Data(
                    (
                        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                            + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
                            + (request.options.includesColumnNames
                                && request.options.xlsxFreezesHeader
                                ? "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
                                : "")
                            + "<sheetData>"
                    ).utf8
                ),
                to: &worksheetEntry!
            )
            sheetRowCount = 0
            if request.options.includesColumnNames {
                var headerData = Data()
                appendHeaderRow(
                    request.columns,
                    columnReferences: columnReferences,
                    rowNumber: 1,
                    to: &headerData
                )
                try archive.write(headerData, to: &worksheetEntry!)
                sheetRowCount = 1
            }
        }

        func finishSheet() throws {
            guard var entry = worksheetEntry else { return }
            var suffix = "</sheetData>"
            if request.options.includesColumnNames
                && request.options.xlsxAddsAutoFilter
            {
                let lastColumn = columnLetters(
                    for: max(0, request.columns.count - 1)
                )
                suffix += "<autoFilter ref=\"A1:\(lastColumn)\(max(1, sheetRowCount))\"/>"
            }
            suffix += "</worksheet>"
            try archive.write(Data(suffix.utf8), to: &entry)
            try archive.finishEntry(&entry)
            worksheetEntry = nil
        }

        try beginSheet()
        var nextBatch = try await request.source.nextBatch()
        while let batch = nextBatch {
            async let prefetchedBatch = request.source.nextBatch()
            try Task.checkCancellation()
            var batchData = Data()
            batchData.reserveCapacity(
                min(8 * 1_024 * 1_024, batch.count * request.columns.count * 48)
            )
            for (batchIndex, row) in batch.enumerated() {
                if batchIndex.isMultiple(of: 256) {
                    try Task.checkCancellation()
                }
                if sheetRowCount == maximumRowsPerSheet {
                    if !batchData.isEmpty {
                        try archive.write(batchData, to: &worksheetEntry!)
                        batchData.removeAll(keepingCapacity: true)
                    }
                    try finishSheet()
                    try beginSheet()
                }
                appendDataRow(
                    row,
                    columns: request.columns,
                    columnReferences: columnReferences,
                    nullStyle: request.options.nullStyle,
                    rowNumber: sheetRowCount + 1,
                    to: &batchData
                )
                sheetRowCount += 1
                totalRowCount += 1
                if totalRowCount.isMultiple(of: 128) {
                    await progressReporter.reportIfNeeded(totalRowCount)
                }
            }
            if !batchData.isEmpty {
                try archive.write(batchData, to: &worksheetEntry!)
            }
            nextBatch = try await prefetchedBatch
            await Task.yield()
        }
        await progressReporter.reportIfNeeded(totalRowCount, force: true)
        try finishSheet()

        try archive.writeEntry(
            path: "[Content_Types].xml",
            data: contentTypesXML(sheetCount: sheetNames.count)
        )
        try archive.writeEntry(path: "_rels/.rels", data: packageRelsXML())
        try archive.writeEntry(
            path: "xl/workbook.xml",
            data: workbookXML(sheetNames: sheetNames)
        )
        try archive.writeEntry(
            path: "xl/_rels/workbook.xml.rels",
            data: workbookRelsXML(sheetCount: sheetNames.count)
        )
        try archive.writeEntry(path: "xl/styles.xml", data: stylesXML())
        try archive.finish()
        return totalRowCount
    }

    private static func appendHeaderRow(
        _ columns: [WorkspaceGridCopyColumn],
        columnReferences: [String],
        rowNumber: Int,
        to data: inout Data
    ) {
        let rowNumberText = String(rowNumber)
        data.appendUTF8("<row r=\"")
        data.appendUTF8(rowNumberText)
        data.appendUTF8("\">")
        for (columnIndex, column) in columns.enumerated() {
            appendCell(
                value: column.name,
                columnReference: columnReferences[columnIndex],
                rowNumberText: rowNumberText,
                isHeader: true,
                to: &data
            )
        }
        data.appendUTF8("</row>")
    }

    private static func appendDataRow(
        _ row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceGridCopyColumn],
        columnReferences: [String],
        nullStyle: WorkspaceDataExportNullStyle,
        rowNumber: Int,
        to data: inout Data
    ) {
        let rowNumberText = String(rowNumber)
        data.appendUTF8("<row r=\"")
        data.appendUTF8(rowNumberText)
        data.appendUTF8("\">")
        for (columnIndex, column) in columns.enumerated() {
            let value: String?
            switch row.value(at: column.dataIndex) {
            case .null:
                value = nullStyle == .empty ? nil : nullStyle.text
            case let .text(text):
                value = text
            case let .binary(byteCount, _):
                value = "<BINARY \(byteCount) bytes>"
            }
            guard let value else { continue }
            appendCell(
                value: value,
                columnReference: columnReferences[columnIndex],
                rowNumberText: rowNumberText,
                isHeader: false,
                to: &data
            )
        }
        data.appendUTF8("</row>")
    }

    private static func appendCell(
        value: String,
        columnReference: String,
        rowNumberText: String,
        isHeader: Bool,
        to data: inout Data
    ) {
        data.appendUTF8("<c r=\"")
        data.appendUTF8(columnReference)
        data.appendUTF8(rowNumberText)
        if isHeader {
            data.appendUTF8(
                "\" t=\"inlineStr\" s=\"1\"><is><t xml:space=\"preserve\">"
            )
        } else {
            data.appendUTF8(
                "\" t=\"inlineStr\"><is><t xml:space=\"preserve\">"
            )
        }
        data.appendXMLEscaped(value)
        data.appendUTF8("</t></is></c>")
    }

    private static func columnLetters(for index: Int) -> String {
        var result = ""
        var value = index
        repeat {
            result = String(
                UnicodeScalar(65 + (value % 26))!
            ) + result
            value = value / 26 - 1
        } while value >= 0
        return result
    }

    private static func uniqueSheetName(
        baseName: String,
        number: Int,
        existingNames: [String]
    ) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/?*[]:")
        let filteredScalars = baseName.unicodeScalars.filter {
            !invalidCharacters.contains($0)
        }
        var base = String(String.UnicodeScalarView(filteredScalars))
        if base.isEmpty {
            base = AppCopy.current.text("结果", "Result")
        }
        let suffix = number == 1 ? "" : " (\(number))"
        base = String(base.prefix(max(1, 31 - suffix.count)))
        var candidate = base + suffix
        var disambiguator = 2
        while existingNames.contains(candidate) {
            let extra = " \(disambiguator)"
            candidate = String(base.prefix(max(1, 31 - extra.count))) + extra
            disambiguator += 1
        }
        return candidate
    }

    private static func contentTypesXML(sheetCount: Int) -> Data {
        var value =
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            + "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        for index in 1...sheetCount {
            value += "<Override PartName=\"/xl/worksheets/sheet\(index).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        value += "</Types>"
        return Data(value.utf8)
    }

    private static func packageRelsXML() -> Data {
        Data(
            (
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                    + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                    + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
                    + "</Relationships>"
            ).utf8
        )
    }

    private static func workbookXML(sheetNames: [String]) -> Data {
        var data = Data(
            (
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                    + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>"
            ).utf8
        )
        for (index, name) in sheetNames.enumerated() {
            data.appendUTF8("<sheet name=\"")
            data.appendXMLEscaped(name)
            data.appendUTF8(
                "\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
            )
        }
        data.appendUTF8("</sheets></workbook>")
        return data
    }

    private static func workbookRelsXML(sheetCount: Int) -> Data {
        var value =
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for index in 1...sheetCount {
            value += "<Relationship Id=\"rId\(index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index).xml\"/>"
        }
        value += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            + "</Relationships>"
        return Data(value.utf8)
    }

    private static func stylesXML() -> Data {
        Data(
            (
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                    + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
                    + "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Aptos\"/></font><font><b/><sz val=\"11\"/><name val=\"Aptos\"/></font></fonts>"
                    + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
                    + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
                    + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
                    + "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/></cellXfs>"
                    + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
                    + "</styleSheet>"
            ).utf8
        )
    }
}

private struct WorkspaceStreamingZIPWriter {
    private static let flushThreshold = 256 * 1_024

    struct Entry {
        let pathData: Data
        let localHeaderOffset: UInt32
        let deflater: WorkspaceRawDeflater
        var crc: UInt32 = 0
        var compressedSize: UInt32 = 0
        var uncompressedSize: UInt32 = 0
    }

    private struct CompletedEntry {
        let pathData: Data
        let localHeaderOffset: UInt32
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
    }

    private let fileHandle: FileHandle
    private var offset: UInt32 = 0
    private var entries: [CompletedEntry] = []
    private var outputBuffer = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        outputBuffer.reserveCapacity(Self.flushThreshold)
    }

    mutating func beginEntry(path: String) throws -> Entry {
        let pathData = Data(path.utf8)
        guard pathData.count <= UInt16.max else {
            throw WorkspaceDataExportError.fileTooLarge
        }
        var header = Data()
        header.appendUInt32(0x04034B50)
        header.appendUInt16(20)
        header.appendUInt16(0x0008)
        header.appendUInt16(8)
        header.appendUInt16(0)
        header.appendUInt16(0)
        header.appendUInt32(0)
        header.appendUInt32(0)
        header.appendUInt32(0)
        header.appendUInt16(UInt16(pathData.count))
        header.appendUInt16(0)
        header.append(pathData)
        let localHeaderOffset = offset
        try append(header)
        return Entry(
            pathData: pathData,
            localHeaderOffset: localHeaderOffset,
            deflater: try WorkspaceRawDeflater()
        )
    }

    mutating func write(_ data: Data, to entry: inout Entry) throws {
        guard data.count <= UInt32.max - entry.uncompressedSize else {
            throw WorkspaceDataExportError.fileTooLarge
        }
        entry.crc = WorkspaceCRC32.update(entry.crc, with: data)
        entry.uncompressedSize += UInt32(data.count)
        var compressedSize = entry.compressedSize
        try entry.deflater.write(data) { compressedData in
            guard
                compressedData.count
                    <= UInt32.max - compressedSize
            else {
                throw WorkspaceDataExportError.fileTooLarge
            }
            compressedSize += UInt32(compressedData.count)
            try append(compressedData)
        }
        entry.compressedSize = compressedSize
    }

    mutating func finishEntry(_ entry: inout Entry) throws {
        var compressedSize = entry.compressedSize
        try entry.deflater.finish { compressedData in
            guard
                compressedData.count
                    <= UInt32.max - compressedSize
            else {
                throw WorkspaceDataExportError.fileTooLarge
            }
            compressedSize += UInt32(compressedData.count)
            try append(compressedData)
        }
        entry.compressedSize = compressedSize
        let finalCRC = WorkspaceCRC32.finalize(entry.crc)
        var descriptor = Data()
        descriptor.appendUInt32(0x08074B50)
        descriptor.appendUInt32(finalCRC)
        descriptor.appendUInt32(entry.compressedSize)
        descriptor.appendUInt32(entry.uncompressedSize)
        try append(descriptor)
        entries.append(
            CompletedEntry(
                pathData: entry.pathData,
                localHeaderOffset: entry.localHeaderOffset,
                crc: finalCRC,
                compressedSize: entry.compressedSize,
                uncompressedSize: entry.uncompressedSize
            )
        )
    }

    mutating func writeEntry(path: String, data: Data) throws {
        var entry = try beginEntry(path: path)
        try write(data, to: &entry)
        try finishEntry(&entry)
    }

    mutating func finish() throws {
        guard entries.count <= UInt16.max else {
            throw WorkspaceDataExportError.tooManyWorksheets
        }
        let centralDirectoryOffset = offset
        for entry in entries {
            var record = Data()
            record.appendUInt32(0x02014B50)
            record.appendUInt16(20)
            record.appendUInt16(20)
            record.appendUInt16(0x0008)
            record.appendUInt16(8)
            record.appendUInt16(0)
            record.appendUInt16(0)
            record.appendUInt32(entry.crc)
            record.appendUInt32(entry.compressedSize)
            record.appendUInt32(entry.uncompressedSize)
            record.appendUInt16(UInt16(entry.pathData.count))
            record.appendUInt16(0)
            record.appendUInt16(0)
            record.appendUInt16(0)
            record.appendUInt16(0)
            record.appendUInt32(0)
            record.appendUInt32(entry.localHeaderOffset)
            record.append(entry.pathData)
            try append(record)
        }
        let centralDirectorySize = offset - centralDirectoryOffset
        var end = Data()
        end.appendUInt32(0x06054B50)
        end.appendUInt16(0)
        end.appendUInt16(0)
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt32(centralDirectorySize)
        end.appendUInt32(centralDirectoryOffset)
        end.appendUInt16(0)
        try append(end)
        try flush()
    }

    private mutating func append(_ data: Data) throws {
        guard data.count <= UInt32.max - offset else {
            throw WorkspaceDataExportError.fileTooLarge
        }
        offset += UInt32(data.count)
        if outputBuffer.isEmpty, data.count >= Self.flushThreshold {
            try fileHandle.write(contentsOf: data)
            return
        }
        outputBuffer.append(data)
        if outputBuffer.count >= Self.flushThreshold {
            try flush()
        }
    }

    private mutating func flush() throws {
        guard !outputBuffer.isEmpty else { return }
        try fileHandle.write(contentsOf: outputBuffer)
        outputBuffer.removeAll(keepingCapacity: true)
    }
}

private final class WorkspaceRawDeflater {
    private static let outputChunkSize = 256 * 1_024

    private var stream = z_stream()
    private var isInitialized = false

    init() throws {
        let status = deflateInit2_(
            &stream,
            Z_BEST_SPEED,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw WorkspaceDataExportError.unableToCompressFile
        }
        isInitialized = true
    }

    deinit {
        if isInitialized {
            deflateEnd(&stream)
        }
    }

    func write(
        _ data: Data,
        emit: (Data) throws -> Void
    ) throws {
        guard !data.isEmpty else { return }
        var output = [UInt8](
            repeating: 0,
            count: Self.outputChunkSize
        )
        try data.withUnsafeBytes { rawBuffer in
            guard
                let baseAddress = rawBuffer
                    .bindMemory(to: Bytef.self)
                    .baseAddress
            else {
                return
            }
            stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
            stream.avail_in = uInt(rawBuffer.count)
            defer {
                stream.next_in = nil
                stream.avail_in = 0
                stream.next_out = nil
                stream.avail_out = 0
            }

            repeat {
                let result = deflate(
                    output: &output,
                    flush: Z_NO_FLUSH
                )
                guard result.status == Z_OK else {
                    throw WorkspaceDataExportError.unableToCompressFile
                }
                if !result.data.isEmpty {
                    try emit(result.data)
                }
            } while stream.avail_in > 0
        }
    }

    func finish(emit: (Data) throws -> Void) throws {
        guard isInitialized else { return }
        defer {
            deflateEnd(&stream)
            isInitialized = false
        }
        var output = [UInt8](
            repeating: 0,
            count: Self.outputChunkSize
        )
        while true {
            let result = deflate(output: &output, flush: Z_FINISH)
            guard result.status == Z_OK || result.status == Z_STREAM_END else {
                throw WorkspaceDataExportError.unableToCompressFile
            }
            if !result.data.isEmpty {
                try emit(result.data)
            }
            if result.status == Z_STREAM_END {
                return
            }
        }
    }

    private func deflate(
        output: inout [UInt8],
        flush: Int32
    ) -> (status: Int32, data: Data) {
        let status = output.withUnsafeMutableBytes { rawBuffer in
            stream.next_out = rawBuffer
                .bindMemory(to: Bytef.self)
                .baseAddress
            stream.avail_out = uInt(rawBuffer.count)
            return zlib.deflate(&stream, flush)
        }
        let byteCount = output.count - Int(stream.avail_out)
        return (
            status,
            byteCount == 0
                ? Data()
                : Data(output.prefix(byteCount))
        )
    }
}

private enum WorkspaceCRC32 {
    static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            guard
                let baseAddress = rawBuffer
                    .bindMemory(to: Bytef.self)
                    .baseAddress
            else {
                return crc
            }
            return UInt32(
                zlib.crc32(
                    uLong(crc),
                    baseAddress,
                    uInt(rawBuffer.count)
                )
            )
        }
    }

    static func finalize(_ crc: UInt32) -> UInt32 {
        crc
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        string.utf8.withContiguousStorageIfAvailable { buffer in
            if let baseAddress = buffer.baseAddress {
                append(baseAddress, count: buffer.count)
            }
        } ?? append(contentsOf: string.utf8)
    }

    mutating func appendXMLEscaped(_ text: String) {
        let requiresEscaping = text.utf8.contains { byte in
            switch byte {
            case 0x26, 0x3C, 0x3E, 0x22, 0x27,
                 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F:
                true
            default:
                false
            }
        }
        guard requiresEscaping else {
            appendUTF8(text)
            return
        }
        for byte in text.utf8 {
            switch byte {
            case 0x26:
                appendUTF8("&amp;")
            case 0x3C:
                appendUTF8("&lt;")
            case 0x3E:
                appendUTF8("&gt;")
            case 0x22:
                appendUTF8("&quot;")
            case 0x27:
                appendUTF8("&apos;")
            case 0x09, 0x0A, 0x0D:
                append(byte)
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F:
                continue
            default:
                append(byte)
            }
        }
    }

    mutating func appendUInt16(_ value: UInt16) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) {
            append(contentsOf: $0)
        }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) {
            append(contentsOf: $0)
        }
    }
}
