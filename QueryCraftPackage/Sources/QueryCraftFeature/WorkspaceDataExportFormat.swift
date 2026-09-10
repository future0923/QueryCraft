import UniformTypeIdentifiers

enum WorkspaceDataExportFormat: String, CaseIterable, Identifiable, Sendable {
    case xlsx
    case csv
    case json
    case sql

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
