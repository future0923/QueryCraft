import Foundation

actor WorkspaceQueryResultInspectorFormatter {
    static let shared = WorkspaceQueryResultInspectorFormatter()
    private static let maximumFormattedByteCount = 1_000_000

    func formattedJSON(_ text: String) throws -> String? {
        try Task.checkCancellation()
        let data = Data(text.utf8)
        guard data.count <= Self.maximumFormattedByteCount else { return nil }
        return try ElasticsearchJSONWhitespaceFormatter.format(data)
    }
}
