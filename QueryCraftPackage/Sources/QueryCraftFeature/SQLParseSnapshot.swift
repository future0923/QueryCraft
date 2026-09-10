import Foundation

struct SQLStatement: Equatable, Sendable {
    let kind: SQLStatementKind
    let range: SQLSourceRange
}

struct SQLParseDiagnostic: Equatable, Hashable, Sendable {
    enum Reason: Equatable, Hashable, Sendable {
        case syntaxError
        case missingSyntax
        case unsupportedSyntax
    }

    let range: SQLSourceRange
    let reason: Reason
}

struct SQLParseSnapshot: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case full
        case incremental
    }

    let revision: SQLSourceRevision
    let sourceLength: Int
    let statements: [SQLStatement]
    let unreliableStatementRanges: [SQLSourceRange]
    let diagnostics: [SQLParseDiagnostic]
    let changedRanges: [SQLSourceRange]
    let mode: Mode
    let syntaxTree: SQLSyntaxNodeSnapshot
    let relationReferences: [SQLRelationReferenceSnapshot]
    let queryScopes: [SQLQueryScopeSnapshot]

    var isReliable: Bool {
        diagnostics.isEmpty
    }

    func queryScopePath(
        atUTF16Location location: Int
    ) -> [SQLQueryScopeSnapshot] {
        queryScopes
            .filter {
                location >= $0.range.location
                    && location <= $0.range.upperBound
            }
            .sorted {
                if $0.range.length == $1.range.length {
                    return $0.range.location > $1.range.location
                }
                return $0.range.length < $1.range.length
            }
            .lazy
            .compactMap { $0.path(atUTF16Location: location) }
            .first ?? []
    }

    func statement(atUTF16Location location: Int, in source: String) -> SQLStatement? {
        guard (source as NSString).length == sourceLength,
              location >= 0,
              location <= sourceLength
        else {
            return nil
        }
        if unreliableStatementRanges.contains(where: { range in
            range.contains(location)
                || isInsertionPointAfterTerminatingSemicolon(
                    location,
                    range: range,
                    source: source
                )
        }) {
            return nil
        }

        if let containing = statements.first(where: { statement in
            statement.range.contains(location)
                || isInsertionPointAfterTerminatingSemicolon(
                    location,
                    range: statement.range,
                    source: source
                )
        }) {
            return containing
        }

        let followingStatement = statements.first(where: {
            $0.range.location > location
        })
        let followingUnreliableRange = unreliableStatementRanges.first(where: {
            $0.location > location
        })
        if let followingUnreliableRange,
           followingStatement == nil
            || followingUnreliableRange.location
                < followingStatement?.range.location ?? .max
        {
            return nil
        }
        if let followingStatement {
            return followingStatement
        }

        let precedingStatement = statements.last(where: {
            $0.range.upperBound <= location
        })
        let precedingUnreliableRange = unreliableStatementRanges.last(where: {
            $0.upperBound <= location
        })
        if let precedingUnreliableRange,
           precedingStatement == nil
            || precedingUnreliableRange.upperBound
                > precedingStatement?.range.upperBound ?? .min
        {
            return nil
        }
        return precedingStatement
    }

    func unreliableStatementRange(
        atUTF16Location location: Int,
        in source: String
    ) -> SQLSourceRange? {
        guard (source as NSString).length == sourceLength,
              location >= 0,
              location <= sourceLength
        else {
            return nil
        }

        if let containing = unreliableStatementRanges.first(where: { range in
            range.contains(location)
                || isInsertionPointAfterTerminatingSemicolon(
                    location,
                    range: range,
                    source: source
                )
        }) {
            return containing
        }

        let followingStatement = statements.first(where: {
            $0.range.location > location
        })
        if let following = unreliableStatementRanges.first(where: {
            $0.location > location
        }), followingStatement == nil
            || following.location < followingStatement?.range.location ?? .max
        {
            return following
        }

        let precedingStatement = statements.last(where: {
            $0.range.upperBound <= location
        })
        if let preceding = unreliableStatementRanges.last(where: {
            $0.upperBound <= location
        }), precedingStatement == nil
            || preceding.upperBound > precedingStatement?.range.upperBound ?? .min
        {
            return preceding
        }
        return nil
    }

    private func isInsertionPointAfterTerminatingSemicolon(
        _ location: Int,
        range: SQLSourceRange,
        source: String
    ) -> Bool {
        guard location == range.upperBound,
              range.length > 0,
              range.upperBound <= (source as NSString).length
        else {
            return false
        }
        let lastCharacterRange = NSRange(
            location: range.upperBound - 1,
            length: 1
        )
        return (source as NSString).substring(with: lastCharacterRange) == ";"
    }
}
