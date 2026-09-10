struct SQLFormattingOptions: Equatable, Sendable {
    static let standard = SQLFormattingOptions(
        keywordCase: .uppercase,
        indentationUnit: "    "
    )

    let keywordCase: SQLKeywordCase
    let indentationUnit: String
}
