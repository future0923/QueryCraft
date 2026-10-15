import UniformTypeIdentifiers

enum WorkspaceDataExportFormat: String, CaseIterable, Identifiable, Sendable {
    case xlsx
    case csv
    case json
    case sql

    static let contextMenuFormats: [Self] = [.csv, .json, .sql, .xlsx]

    var menuTitle: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        case .sql: "SQL INSERT"
        case .xlsx: "XLSX"
        }
    }

    var systemImage: String {
        switch self {
        case .csv: "tablecells"
        case .json: "curlybraces"
        case .sql: "terminal"
        case .xlsx: "tablecells.fill"
        }
    }

    var id: Self { self }

    var fileExtension: String { rawValue }

    var contentType: UTType {
        switch self {
        case .xlsx:
            UTType(filenameExtension: fileExtension) ?? .data
        case .csv:
            .commaSeparatedText
        case .json:
            .json
        case .sql:
            UTType(filenameExtension: fileExtension) ?? .plainText
        }
    }
}
