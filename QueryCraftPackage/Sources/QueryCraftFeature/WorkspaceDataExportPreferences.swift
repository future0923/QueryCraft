import Foundation

/// Persistent file settings only. Source objects, selections and paths never live here.
struct WorkspaceDataExportPreferences: Codable, Equatable, Sendable {
    var includesColumnNames = true
    var nullStyle = WorkspaceDataExportNullStyle.literal
    var csvIncludesUTF8BOM = true
    var csvDelimiter = WorkspaceCSVDelimiter.comma
    var csvLineEnding = WorkspaceCSVLineEnding.crlf
    var csvQuotePolicy = WorkspaceCSVQuotePolicy.asNeeded
    var sanitizesSpreadsheetFormulas = true
    var jsonLayout = WorkspaceJSONLayout.objects
    var prettyPrintsJSON = true
    var xlsxFreezesHeader = true
    var xlsxAddsAutoFilter = true
    var sqlInsertBatchSize = 1_000
    var sqlWrapsInTransaction = false
    var sqlIncludesDatabaseName = false

    static let batchSizeRange = 1...100_000

    var isValid: Bool { Self.batchSizeRange.contains(sqlInsertBatchSize) }

    func options(for format: WorkspaceDataExportFormat) -> WorkspaceDataExportOptions {
        var options = WorkspaceDataExportOptions()
        options.format = format
        options.includesColumnNames = includesColumnNames
        options.nullStyle = nullStyle
        options.csvIncludesUTF8BOM = csvIncludesUTF8BOM
        options.csvDelimiter = csvDelimiter
        options.csvLineEnding = csvLineEnding
        options.csvQuotePolicy = csvQuotePolicy
        options.sanitizesSpreadsheetFormulas = sanitizesSpreadsheetFormulas
        options.jsonLayout = jsonLayout
        options.prettyPrintsJSON = prettyPrintsJSON
        options.xlsxFreezesHeader = xlsxFreezesHeader
        options.xlsxAddsAutoFilter = xlsxAddsAutoFilter
        options.sqlInsertBatchSize = isValid ? sqlInsertBatchSize : 1_000
        options.sqlWrapsInTransaction = sqlWrapsInTransaction
        return options
    }
}
