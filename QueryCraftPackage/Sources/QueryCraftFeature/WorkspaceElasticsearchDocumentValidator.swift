import Foundation

actor WorkspaceElasticsearchDocumentValidator {
    static let maximumByteCount = 1_048_576

    func validate(_ text: String) throws -> Data {
        try Task.checkCancellation()
        let data = Data(text.utf8)
        return try validate(data)
    }

    func validate(_ data: Data) throws -> Data {
        try Task.checkCancellation()
        guard data.count <= Self.maximumByteCount else {
            throw WorkspaceDocumentEditingError.sourceTooLarge(
                Self.maximumByteCount
            )
        }
        guard let root = try? JSONSerialization.jsonObject(with: data),
              root is [String: Any]
        else {
            throw WorkspaceDocumentEditingError.invalidSource
        }
        try Task.checkCancellation()
        return data
    }
}
