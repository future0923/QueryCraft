import SwiftTreeSitter

public final class TreeSitterModel: Sendable {
    public static let shared = TreeSitterModel()

    private let sqlQuery: Query?
    private let jsonQuery: Query?

    private init() {
        sqlQuery = try? CodeLanguage.sql.language.flatMap { language in
            guard let url = CodeLanguage.sql.queryURL else { return nil }
            return try Query(language: language, url: url)
        }
        jsonQuery = try? CodeLanguage.json.language.flatMap { language in
            guard let url = CodeLanguage.json.queryURL else { return nil }
            return try Query(language: language, url: url)
        }
    }

    public func query(for language: TreeSitterLanguage) -> Query? {
        switch language {
        case .sql:
            sqlQuery
        case .json:
            jsonQuery
        case .plainText:
            nil
        }
    }
}
