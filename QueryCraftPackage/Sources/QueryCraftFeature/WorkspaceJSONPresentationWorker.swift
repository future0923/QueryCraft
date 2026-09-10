import Foundation

actor WorkspaceJSONPresentationWorker {
    /// Only whitespace changes. Invalid/truncated responses remain available in
    /// full, and automatic detection never treats a plain scalar as a document.
    func format(_ source: String, automatic: Bool) throws -> String? {
        try Task.checkCancellation()
        if automatic {
            let first = source.utf8.first { ![9, 10, 13, 32].contains($0) }
            guard first == 123 || first == 91 else { return nil }
        }
        do {
            return try ElasticsearchJSONWhitespaceFormatter.format(Data(source.utf8))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return automatic ? nil : source
        }
    }
}
