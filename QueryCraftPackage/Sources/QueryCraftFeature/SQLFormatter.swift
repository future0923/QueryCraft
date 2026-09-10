import Foundation

enum SQLFormatter {
    static func formattingEdit(
        target: SQLExecutionTarget,
        originalSelection: NSRange,
        parseSnapshot: SQLParseSnapshot,
        options: SQLFormattingOptions = .standard
    ) throws -> SQLFormattingEdit? {
        try Task.checkCancellation()
        let source = target.source
        let sourceLength = (source.text as NSString).length
        guard parseSnapshot.revision == source.revision,
              parseSnapshot.sourceLength == sourceLength
        else {
            throw SQLFormattingError.sourceChanged
        }
        guard target.range.location >= 0,
              target.range.length > 0,
              target.range.upperBound <= sourceLength
        else {
            throw SQLFormattingError.invalidSelection
        }
        let original = (source.text as NSString).substring(
            with: target.range.nsRange
        )
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLFormattingError.noSQLInTarget
        }

        var allTokens: [Token] = []
        try collectTokens(
            in: parseSnapshot.syntaxTree,
            source: source.text,
            ancestors: [],
            into: &allTokens
        )
        let targetTokens = try gapPreservingTokens(
            allTokens,
            in: target.range,
            source: source.text
        )
        guard !targetTokens.isEmpty else { return nil }
        let multilineLists = try multilineListRanges(
            in: parseSnapshot.syntaxTree
        )
        let rendered = try render(
            targetTokens,
            multilineLists: multilineLists,
            lineEnding: lineEnding(in: source.text),
            options: options
        )
        guard rendered.text != original else { return nil }

        return SQLFormattingEdit(
            sourceRevision: source.revision,
            range: target.range,
            replacement: rendered.text,
            selectedRange: formattedSelection(
                target: target,
                originalSelection: originalSelection,
                rendered: rendered
            )
        )
    }

    private static func collectTokens(
        in node: SQLSyntaxNodeSnapshot,
        source: String,
        ancestors: [NodeContext],
        into tokens: inout [Token]
    ) throws {
        try Task.checkCancellation()
        guard node.range.length > 0 else { return }
        if node.isLeaf || (node.type == "identifier" && !node.children.isEmpty) {
            tokens.append(
                Token(
                    type: node.type,
                    text: (source as NSString).substring(with: node.range.nsRange),
                    range: node.range,
                    ancestors: ancestors
                )
            )
            return
        }

        let context = NodeContext(type: node.type, range: node.range)
        for child in node.children {
            try collectTokens(
                in: child,
                source: source,
                ancestors: ancestors + [context],
                into: &tokens
            )
        }
    }

    private static func gapPreservingTokens(
        _ tokens: [Token],
        in target: SQLSourceRange,
        source: String
    ) throws -> [Token] {
        try Task.checkCancellation()
        let containedTokens = tokens
            .filter { target.contains($0.range) }
            .sorted {
                if $0.range.location == $1.range.location {
                    return $0.range.length < $1.range.length
                }
                return $0.range.location < $1.range.location
            }
        var result: [Token] = []
        var sourceLocation = target.location

        for token in containedTokens {
            try Task.checkCancellation()
            guard token.range.location >= sourceLocation else { continue }
            appendOpaqueGap(
                from: sourceLocation,
                to: token.range.location,
                source: source,
                into: &result
            )
            result.append(token)
            sourceLocation = token.range.upperBound
        }
        appendOpaqueGap(
            from: sourceLocation,
            to: target.upperBound,
            source: source,
            into: &result
        )
        return result
    }

    private static func appendOpaqueGap(
        from start: Int,
        to end: Int,
        source: String,
        into tokens: inout [Token]
    ) {
        guard end > start else { return }
        let sourceString = source as NSString
        let gapRange = NSRange(location: start, length: end - start)
        let gap = sourceString.substring(with: gapRange) as NSString
        let nonWhitespace = CharacterSet.whitespacesAndNewlines.inverted
        let first = gap.rangeOfCharacter(from: nonWhitespace)
        guard first.location != NSNotFound else { return }
        let last = gap.rangeOfCharacter(
            from: nonWhitespace,
            options: .backwards
        )
        let preservedRange = NSRange(
            location: start + first.location,
            length: NSMaxRange(last) - first.location
        )
        tokens.append(Token(
            type: "unparsed",
            text: sourceString.substring(with: preservedRange),
            range: SQLSourceRange(preservedRange),
            ancestors: []
        ))
    }

    private static func multilineListRanges(
        in node: SQLSyntaxNodeSnapshot
    ) throws -> Set<SQLSourceRange> {
        try Task.checkCancellation()
        var result: Set<SQLSourceRange> = []
        if node.type == "select_expression" {
            if node.children.contains(where: { $0.type == "," }) {
                result.insert(node.range)
            }
        } else if ["group_by", "order_by", "from"].contains(node.type),
                  node.children.contains(where: { $0.type == "," }) {
            result.insert(node.range)
        }
        for child in node.children {
            result.formUnion(try multilineListRanges(in: child))
        }
        return result
    }

    private static func render(
        _ tokens: [Token],
        multilineLists: Set<SQLSourceRange>,
        lineEnding: String,
        options: SQLFormattingOptions
    ) throws -> RenderedSQL {
        var output = ""
        var mappings: [TokenMapping] = []

        for (index, token) in tokens.enumerated() {
            try Task.checkCancellation()
            let previous = index > 0 ? tokens[index - 1] : nil
            if let previous {
                output += separator(
                    after: previous,
                    before: token,
                    multilineLists: multilineLists,
                    lineEnding: lineEnding,
                    options: options
                )
            }
            let tokenText = normalizedText(for: token, options: options)
            let outputLocation = (output as NSString).length
            output += tokenText
            mappings.append(
                TokenMapping(
                    sourceRange: token.range,
                    outputRange: SQLSourceRange(
                        location: outputLocation,
                        length: (tokenText as NSString).length
                    )
                )
            )
        }
        return RenderedSQL(text: output, mappings: mappings)
    }

    private static func separator(
        after previous: Token,
        before current: Token,
        multilineLists: Set<SQLSourceRange>,
        lineEnding: String,
        options: SQLFormattingOptions
    ) -> String {
        if isLineComment(previous) {
            return previous.text.hasSuffix("\n") || previous.text.hasSuffix("\r")
                ? indentation(
                    for: current,
                    multilineLists: multilineLists,
                    options: options
                )
                : lineEnding + indentation(
                    for: current,
                    multilineLists: multilineLists,
                    options: options
                )
        }
        if previous.text == ";" {
            return lineEnding + lineEnding
        }
        if current.startsNode(in: ["cte"]), previous.text == "," {
            return lineEnding + indent(
                level: current.queryDepth,
                options: options
            )
        }
        if isSetOperation(current) {
            return lineEnding + indent(
                level: current.queryDepth,
                options: options
            )
        }
        if current.type == "keyword_select", isSetOperation(previous)
            || previous.type == "keyword_all"
                && previous.hasAncestor(in: ["set_operation"])
        {
            return lineEnding + indent(
                level: current.queryDepth,
                options: options
            )
        }
        if current.type == "keyword_select",
           current.startsNode(in: ["select"]),
           previous.text != "("
        {
            return lineEnding + indent(
                level: current.queryDepth,
                options: options
            )
        }
        if opensNestedQuery(previous, current: current) {
            return lineEnding + indent(
                level: current.queryDepth,
                options: options
            )
        }
        if closesNestedQuery(current, previous: previous) {
            return lineEnding + indent(
                level: max(0, current.queryDepth - 1),
                options: options
            )
        }
        if current.startsNode(in: [
            "from", "where", "group_by", "having", "order_by", "limit"
        ]) || current.startsNode(in: ["join"]) {
            return lineEnding + indent(
                level: current.queryDepth,
                options: options
            )
        }
        if current.type == "keyword_on", current.parentType == "join" {
            return lineEnding + indent(
                level: current.queryDepth + 1,
                options: options
            )
        }
        if ["keyword_and", "keyword_or"].contains(current.type),
           current.hasAncestor(in: ["where", "join", "having"])
        {
            return lineEnding + indent(
                level: current.queryDepth + 1,
                options: options
            )
        }
        if ["keyword_where", "keyword_having"].contains(previous.type) {
            return lineEnding + indent(
                level: current.queryDepth + 1,
                options: options
            )
        }
        if current.type == "keyword_distinct",
           previous.type == "keyword_select"
        {
            return " "
        }
        if ["keyword_select", "keyword_distinct", "keyword_from", "keyword_limit"]
            .contains(previous.type)
        {
            return lineEnding + indent(
                level: current.queryDepth + 1,
                options: options
            )
        }
        if previous.type == "keyword_by" {
            return lineEnding + indent(
                level: current.queryDepth + 1,
                options: options
            )
        }
        if previous.text == ",", previous.isInside(multilineLists) {
            return lineEnding + indent(
                level: current.queryDepth + 1,
                options: options
            )
        }

        if [",", ";", ")", "]", ".", "`"].contains(current.text) {
            return ""
        }
        if ["(", "[", ".", "`"].contains(previous.text) {
            return ""
        }
        if current.text == "(", current.hasAncestor(in: ["invocation"]) {
            return ""
        }
        return " "
    }

    private static func normalizedText(
        for token: Token,
        options: SQLFormattingOptions
    ) -> String {
        if token.type.hasPrefix("keyword_") {
            return cased(token.text, as: options.keywordCase)
        }
        if token.type == "identifier",
           token.hasAncestor(in: ["invocation"]),
           SQLStaticCatalog.builtInFunctionSet.contains(token.text.uppercased())
        {
            return cased(token.text, as: options.keywordCase)
        }
        return token.text
    }

    private static func cased(
        _ text: String,
        as keywordCase: SQLKeywordCase
    ) -> String {
        switch keywordCase {
        case .uppercase:
            text.uppercased()
        case .lowercase:
            text.lowercased()
        case .preserve:
            text
        }
    }

    private static func indentation(
        for token: Token,
        multilineLists: Set<SQLSourceRange>,
        options: SQLFormattingOptions
    ) -> String {
        if token.isInside(multilineLists)
            || token.hasAncestor(in: ["where", "join", "having"])
        {
            return indent(level: token.queryDepth + 1, options: options)
        }
        return indent(level: token.queryDepth, options: options)
    }

    private static func indent(
        level: Int,
        options: SQLFormattingOptions
    ) -> String {
        String(repeating: options.indentationUnit, count: max(0, level))
    }

    private static func isSetOperation(_ token: Token) -> Bool {
        ["keyword_union", "keyword_except", "keyword_intersect"]
            .contains(token.type)
    }

    private static func opensNestedQuery(
        _ previous: Token,
        current: Token
    ) -> Bool {
        guard previous.text == "(", current.type == "keyword_select"
                || current.type == "keyword_with"
        else {
            return false
        }
        if previous.parentType == "subquery" {
            return true
        }
        return previous.parentType == "cte"
            && current.statementDepth > previous.statementDepth
    }

    private static func closesNestedQuery(
        _ current: Token,
        previous: Token
    ) -> Bool {
        guard current.text == ")" else { return false }
        if current.parentType == "subquery" {
            return true
        }
        return current.parentType == "cte"
            && previous.statementDepth > current.statementDepth
    }

    private static func formattedSelection(
        target: SQLExecutionTarget,
        originalSelection: NSRange,
        rendered: RenderedSQL
    ) -> NSRange {
        let replacementLength = (rendered.text as NSString).length
        if target.kind == .selection {
            return NSRange(
                location: target.range.location,
                length: replacementLength
            )
        }

        let start = mappedLocation(
            originalSelection.location,
            target: target.range,
            rendered: rendered
        )
        let end = mappedLocation(
            NSMaxRange(originalSelection),
            target: target.range,
            rendered: rendered
        )
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func mappedLocation(
        _ sourceLocation: Int,
        target: SQLSourceRange,
        rendered: RenderedSQL
    ) -> Int {
        let replacementLength = (rendered.text as NSString).length
        guard sourceLocation > target.location else { return target.location }
        guard sourceLocation < target.upperBound else {
            return target.location + replacementLength
        }

        if let mapping = rendered.mappings.first(where: {
            sourceLocation >= $0.sourceRange.location
                && sourceLocation < $0.sourceRange.upperBound
        }) {
            let offset = min(
                sourceLocation - mapping.sourceRange.location,
                mapping.outputRange.length
            )
            return target.location + mapping.outputRange.location + offset
        }
        if let following = rendered.mappings.first(where: {
            $0.sourceRange.location > sourceLocation
        }) {
            return target.location + following.outputRange.location
        }
        return target.location + replacementLength
    }

    private static func isLineComment(_ token: Token) -> Bool {
        guard token.type == "comment" else { return false }
        let trimmed = token.text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("--") || trimmed.hasPrefix("#")
    }

    private static func lineEnding(in source: String) -> String {
        if source.contains("\r\n") { return "\r\n" }
        if source.contains("\r") { return "\r" }
        return "\n"
    }

    private static func intersects(
        _ lhs: SQLSourceRange,
        _ rhs: SQLSourceRange
    ) -> Bool {
        lhs.nsRange.intersection(rhs.nsRange)?.length ?? 0 > 0
    }

    private struct NodeContext {
        let type: String
        let range: SQLSourceRange
    }

    private struct Token {
        let type: String
        let text: String
        let range: SQLSourceRange
        let ancestors: [NodeContext]

        var parentType: String? {
            ancestors.last?.type
        }

        var statementDepth: Int {
            ancestors.count { $0.type == "statement" }
        }

        var queryDepth: Int {
            ancestors.count { $0.type == "subquery" }
                + max(0, statementDepth - 1)
        }

        func hasAncestor(in types: Set<String>) -> Bool {
            ancestors.contains { types.contains($0.type) }
        }

        func startsNode(in types: Set<String>) -> Bool {
            ancestors.contains {
                types.contains($0.type) && $0.range.location == range.location
            }
        }

        func isInside(_ ranges: Set<SQLSourceRange>) -> Bool {
            ancestors.contains { ranges.contains($0.range) }
        }
    }

    private struct TokenMapping {
        let sourceRange: SQLSourceRange
        let outputRange: SQLSourceRange
    }

    private struct RenderedSQL {
        let text: String
        let mappings: [TokenMapping]
    }
}
