struct RedisCommandLineSnapshot {
    let source: String
    let tokenization: RedisCommandTokenization
    let entry: RedisCommandCatalogEntry?

    init(source: String) {
        self.source = source
        tokenization = RedisCommandTokenizer.tokenize(source)
        entry = RedisCommandCatalog.entry(
            named: tokenization.arguments.first
        )
    }

    var isEditingCommandName: Bool {
        tokenization.arguments.count <= 1
            && tokenization.currentTokenRange != nil
    }

    var activeArgumentIndex: Int? {
        guard entry != nil, !isEditingCommandName else { return nil }
        if tokenization.currentTokenRange != nil {
            return max(0, tokenization.arguments.count - 2)
        }
        return max(0, tokenization.arguments.count - 1)
    }

    var currentToken: String { tokenization.currentToken }

    func replacingCurrentToken(with value: String) -> String {
        var result = source
        let replacement = Self.encoded(value)
        if let range = tokenization.currentTokenRange {
            result.replaceSubrange(range, with: replacement)
        } else {
            result.append(replacement)
        }
        result.append(" ")
        return result
    }

    private static func encoded(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" })
        else { return value }
        let escaped = value
            .replacing("\\", with: "\\\\")
            .replacing("\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
