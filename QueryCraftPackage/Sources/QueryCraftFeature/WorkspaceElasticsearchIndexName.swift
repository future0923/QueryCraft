import Foundation

enum WorkspaceElasticsearchIndexName {
    static func encodedPath(_ name: String) throws -> String {
        let forbidden = CharacterSet(charactersIn: "\\/*?\"<>| ,#:")
            .union(.whitespacesAndNewlines).union(.controlCharacters)
        guard !name.isEmpty, name.utf8.count <= 255,
              name == name.lowercased(), name != ".", name != "..",
              !["_", "-", "+"].contains(String(name.prefix(1))),
              name.rangeOfCharacter(from: forbidden) == nil else {
            throw WorkspaceIndexCreationError.name
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw WorkspaceIndexCreationError.name
        }
        return "/" + encoded
    }
}
