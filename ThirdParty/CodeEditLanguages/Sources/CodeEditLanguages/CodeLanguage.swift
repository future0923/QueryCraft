import Foundation
import SwiftTreeSitter
import TreeSitterSQL
import TreeSitterJSON

public struct CodeLanguage: Hashable {
    public let id: TreeSitterLanguage
    public let tsName: String
    public let extensions: Set<String>
    public let lineCommentString: String
    public let rangeCommentStrings: (String, String)
    public let parentQueryURL: URL?
    public let additionalHighlights: Set<String>?
    public let additionalIdentifiers: Set<String>

    public var queryURL: URL? {
        queryURL(for: "highlights")
    }

    public var language: Language? {
        switch id {
        case .sql:
            Language(language: tree_sitter_sql())
        case .json:
            Language(language: tree_sitter_json())
        case .plainText:
            nil
        }
    }

    public static let allLanguages: [CodeLanguage] = [.sql, .json]

    public static let sql = CodeLanguage(
        id: .sql,
        tsName: "sql",
        extensions: ["sql"],
        lineCommentString: "--",
        rangeCommentStrings: ("/*", "*/")
    )

    public static let json = CodeLanguage(
        id: .json,
        tsName: "json",
        extensions: ["json", "ndjson"],
        lineCommentString: "",
        rangeCommentStrings: ("", "")
    )

    public static let `default` = CodeLanguage(
        id: .plainText,
        tsName: "PlainText",
        extensions: ["txt"],
        lineCommentString: "",
        rangeCommentStrings: ("", "")
    )

    public init(
        id: TreeSitterLanguage,
        tsName: String,
        extensions: Set<String>,
        lineCommentString: String,
        rangeCommentStrings: (String, String),
        parentQueryURL: URL? = nil,
        additionalHighlights: Set<String>? = nil,
        additionalIdentifiers: Set<String> = []
    ) {
        self.id = id
        self.tsName = tsName
        self.extensions = extensions
        self.lineCommentString = lineCommentString
        self.rangeCommentStrings = rangeCommentStrings
        self.parentQueryURL = parentQueryURL
        self.additionalHighlights = additionalHighlights
        self.additionalIdentifiers = additionalIdentifiers
    }

    public func queryURL(for highlights: String) -> URL? {
        guard id == .sql || id == .json else { return nil }
        return Bundle.module.resourceURL?
            .appendingPathComponent(
                id == .sql
                    ? "Resources/tree-sitter-sql/\(highlights).scm"
                    : "Resources/tree-sitter-json/\(highlights).scm"
            )
    }

    public static func == (lhs: CodeLanguage, rhs: CodeLanguage) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
