import Foundation

enum SQLExecutionTargetResolver {
    static func resolve(
        _ request: SQLExecutionTargetRequest,
        source: SQLSourceSnapshot,
        selectedRange: NSRange,
        parseSnapshot: SQLParseSnapshot?
    ) throws -> SQLExecutionTarget {
        let documentRange = NSRange(
            location: 0,
            length: (source.text as NSString).length
        )
        switch request {
        case .all:
            guard containsExecutableText(source.text) else {
                throw SQLExecutionTargetError.emptyDocument
            }
            return SQLExecutionTarget(
                kind: .document,
                source: source,
                range: SQLSourceRange(documentRange)
            )

        case .selectionOrCurrentStatement:
            guard selectedRange.location != NSNotFound,
                  selectedRange.location >= 0,
                  selectedRange.length >= 0,
                  NSMaxRange(selectedRange) <= documentRange.length
            else {
                throw SQLExecutionTargetError.invalidSelection
            }
            if selectedRange.length > 0 {
                let selection = (source.text as NSString).substring(
                    with: selectedRange
                )
                if containsExecutableText(selection) {
                    return SQLExecutionTarget(
                        kind: .selection,
                        source: source,
                        range: SQLSourceRange(selectedRange)
                    )
                }
            }

            guard containsExecutableText(source.text) else {
                throw SQLExecutionTargetError.emptyDocument
            }
            guard let parseSnapshot,
                  parseSnapshot.revision == source.revision,
                  parseSnapshot.sourceLength == documentRange.length
            else {
                throw SQLExecutionTargetError.sourceChanged
            }
            guard let statement = parseSnapshot.statement(
                atUTF16Location: selectedRange.location,
                in: source.text
            ) else {
                if parseSnapshot.statements.isEmpty,
                   parseSnapshot.unreliableStatementRanges.isEmpty
                {
                    throw SQLExecutionTargetError.noExecutableStatement
                }
                throw SQLExecutionTargetError.unreliableCurrentStatement
            }
            return SQLExecutionTarget(
                kind: .currentStatement,
                source: source,
                range: statement.range
            )
        }
    }

    private static func containsExecutableText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
