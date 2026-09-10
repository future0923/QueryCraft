import Foundation

struct SQLQuerySyntheticRelationSnapshot: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case commonTableExpression
        case derivedTable
    }

    let kind: Kind
    let range: SQLSourceRange
    let name: String
    let alias: String?
    let outputColumnNames: [String]
}

struct SQLQueryScopeSnapshot: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case statement
        case queryBlock
        case subquery
        case commonTableExpression(name: String?)
        case setOperation
    }

    let kind: Kind
    let range: SQLSourceRange
    let canReferenceParentRelations: Bool
    let relationReferences: [SQLRelationReferenceSnapshot]
    let syntheticRelations: [SQLQuerySyntheticRelationSnapshot]
    let projectedColumnNames: [String]
    let selectListAliases: [String]
    let namedWindows: [String]
    let children: [SQLQueryScopeSnapshot]

    func path(atUTF16Location location: Int) -> [SQLQueryScopeSnapshot]? {
        guard location >= range.location, location <= range.upperBound else {
            return nil
        }
        let childPath = children
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
            .first
        return [self] + (childPath ?? [])
    }
}
