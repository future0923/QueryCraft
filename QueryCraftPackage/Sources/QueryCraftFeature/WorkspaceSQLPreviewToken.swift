public struct WorkspaceSQLPreviewToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case keyword
        case identifier
        case stringLiteral
        case nullLiteral
        case numericLiteral
        case expression
        case punctuation
    }

    public let text: String
    public let kind: Kind

    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }
}
