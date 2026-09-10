import Foundation

actor SQLFormattingWorker {
    func formattingEdit(
        for request: SQLFormattingRequest,
        source: SQLSourceSnapshot,
        selectedRange: NSRange,
        parseSnapshot: SQLParseSnapshot,
        options: SQLFormattingOptions
    ) throws -> SQLFormattingEdit? {
        try Task.checkCancellation()
        let target = try formattingTarget(
            for: request,
            source: source,
            selectedRange: selectedRange,
            parseSnapshot: parseSnapshot
        )
        return try SQLFormatter.formattingEdit(
            target: target,
            originalSelection: selectedRange,
            parseSnapshot: parseSnapshot,
            options: options
        )
    }

    private func formattingTarget(
        for request: SQLFormattingRequest,
        source: SQLSourceSnapshot,
        selectedRange: NSRange,
        parseSnapshot: SQLParseSnapshot
    ) throws -> SQLExecutionTarget {
        let sourceLength = (source.text as NSString).length
        guard selectedRange.location != NSNotFound,
              selectedRange.location >= 0,
              selectedRange.length >= 0,
              NSMaxRange(selectedRange) <= sourceLength
        else {
            throw SQLFormattingError.invalidSelection
        }

        if request == .document {
            guard containsFormattingText(source.text) else {
                throw SQLFormattingError.emptyDocument
            }
            return SQLExecutionTarget(
                kind: .document,
                source: source,
                range: SQLSourceRange(location: 0, length: sourceLength)
            )
        }

        if selectedRange.length > 0 {
            let selection = (source.text as NSString).substring(
                with: selectedRange
            )
            if containsFormattingText(selection) {
                return SQLExecutionTarget(
                    kind: .selection,
                    source: source,
                    range: SQLSourceRange(selectedRange)
                )
            }
        }

        guard containsFormattingText(source.text) else {
            throw SQLFormattingError.emptyDocument
        }
        if let statement = parseSnapshot.statement(
            atUTF16Location: selectedRange.location,
            in: source.text
        ) {
            return SQLExecutionTarget(
                kind: .currentStatement,
                source: source,
                range: statement.range
            )
        }
        if let range = parseSnapshot.unreliableStatementRange(
            atUTF16Location: selectedRange.location,
            in: source.text
        ) {
            return SQLExecutionTarget(
                kind: .currentStatement,
                source: source,
                range: range
            )
        }
        throw SQLFormattingError.noSQLInTarget
    }

    private func containsFormattingText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
