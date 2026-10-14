import Foundation

// Reused tree-sitter subtrees retain identity when edits only move their offsets.
// Copy value snapshots with the same offset delta, including every nested range.
extension SQLSourceRange {
    func shiftedForReuse(by delta: Int) -> Self { .init(location: location + delta, length: length) }
}

extension SQLSyntaxNodeSnapshot {
    func shiftedForReuse(by delta: Int) -> Self {
        guard delta != 0 else { return self }
        return .init(type: type, range: range.shiftedForReuse(by: delta),
                     children: children.map { $0.shiftedForReuse(by: delta) })
    }
}

extension SQLRelationReferenceSnapshot {
    func shiftedForReuse(by delta: Int) -> Self {
        .init(range: range.shiftedForReuse(by: delta), databaseName: databaseName, objectName: objectName, alias: alias)
    }
}

extension SQLQueryScopeSnapshot {
    func shiftedForReuse(by delta: Int) -> Self {
        guard delta != 0 else { return self }
        return .init(kind: kind, range: range.shiftedForReuse(by: delta),
                     canReferenceParentRelations: canReferenceParentRelations,
                     relationReferences: relationReferences.map { $0.shiftedForReuse(by: delta) },
                     syntheticRelations: syntheticRelations.map {
                         .init(kind: $0.kind, range: $0.range.shiftedForReuse(by: delta), name: $0.name,
                               alias: $0.alias, outputColumnNames: $0.outputColumnNames)
                     }, projectedColumnNames: projectedColumnNames, selectListAliases: selectListAliases,
                     namedWindows: namedWindows, children: children.map { $0.shiftedForReuse(by: delta) })
    }
}
