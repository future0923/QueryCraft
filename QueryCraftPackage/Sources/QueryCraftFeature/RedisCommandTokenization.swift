struct RedisCommandTokenization {
    let arguments: [String]
    let currentTokenRange: Range<String.Index>?
    let hasUnterminatedQuote: Bool

    var currentToken: String {
        currentTokenRange == nil ? "" : arguments.last ?? ""
    }
}

enum RedisCommandTokenizer {
    static func tokenize(_ source: String) -> RedisCommandTokenization {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false
        var tokenStarted = false
        var tokenStart: String.Index?

        for index in source.indices {
            let character = source[index]
            if isEscaping {
                current.append(character)
                isEscaping = false
                tokenStarted = true
            } else if character == "\\" {
                tokenStart = tokenStart ?? index
                isEscaping = true
                tokenStarted = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                tokenStart = tokenStart ?? index
                quote = character
                tokenStarted = true
            } else if character.isWhitespace {
                if tokenStarted {
                    arguments.append(current)
                    current = ""
                    tokenStarted = false
                    tokenStart = nil
                }
            } else {
                tokenStart = tokenStart ?? index
                current.append(character)
                tokenStarted = true
            }
        }

        if isEscaping { current.append("\\") }
        if tokenStarted || !current.isEmpty { arguments.append(current) }

        return RedisCommandTokenization(
            arguments: arguments,
            currentTokenRange: tokenStart.map { $0..<source.endIndex },
            hasUnterminatedQuote: quote != nil
        )
    }
}
