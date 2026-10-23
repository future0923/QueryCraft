import Foundation

protocol MobileSQLFormatting: Sendable {
    func edit(for request: SQLFormattingRequest, source: SQLSourceSnapshot, selection: NSRange) async throws -> SQLFormattingEdit?
}

struct MobileSQLFormatter: MobileSQLFormatting {
    func edit(for request: SQLFormattingRequest, source: SQLSourceSnapshot, selection: NSRange) async throws -> SQLFormattingEdit? {
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(source)
        try Task.checkCancellation()
        return try await SQLFormattingWorker().formattingEdit(for: request, source: source,
            selectedRange: selection, parseSnapshot: snapshot, options: .standard)
    }
}

enum MobileSQLFormattingError: LocalizedError {
    case documentTooLarge
    var errorDescription: String? { "SQL 文稿超过 256 KiB，请缩小文稿后格式化。" }
}
