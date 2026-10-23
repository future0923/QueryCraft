import Foundation

/// Platform adapters must reject stale or composing input before replacing text.
enum SQLCompletionApplication {
    struct Insertion {
        let text: String
        let selection: NSRange
        let beginsNextToken: Bool
    }

    static func canApply(_ item: SQLCompletionItem, text: String, selection: NSRange, hasMarkedText: Bool) -> Bool {
        !hasMarkedText && selection.length == 0
            && selection.location == item.replacementRange.upperBound
            && item.replacementRange.location >= 0
            && item.replacementRange.upperBound <= (text as NSString).length
    }

    static func selection(after item: SQLCompletionItem) -> NSRange {
        item.selectionRanges.first?.nsRange ?? NSRange(location: item.replacementRange.location
            + (item.insertionText as NSString).length + item.cursorOffset, length: 0)
    }

    /// Touch keyboards can advance past a completed token in the same undoable
    /// insertion. Functions, placeholders and qualification keep their own caret.
    /// Desktop callers retain the original insertion unless explicitly requested.
    static func insertion(for item: SQLCompletionItem, in text: String, separateToken: Bool = false) -> Insertion {
        let original = Insertion(text: item.insertionText, selection: selection(after: item), beginsNextToken: false)
        guard separateToken, item.cursorOffset == 0, item.selectionRanges.isEmpty,
              [.keyword, .table, .view, .column, .queryOutput].contains(item.kind),
              let last = item.insertionText.last, !last.isWhitespace,
              last.isLetter || last.isNumber || ["_", "`", "\""].contains(last)
        else { return original }
        let source = text as NSString, end = item.replacementRange.upperBound
        guard end >= 0, end <= source.length else { return original }
        if end < source.length {
            let next = source.substring(with: source.rangeOfComposedCharacterSequence(at: end))
            // Reuse a separator already present without eating punctuation,
            // moving into the next line or splitting an identifier at the caret.
            guard next == " " || next == "\t" else { return original }
            return Insertion(text: item.insertionText,
                selection: .init(location: original.selection.location + 1, length: 0), beginsNextToken: true)
        }
        return Insertion(text: item.insertionText + " ",
            selection: .init(location: original.selection.location + 1, length: 0), beginsNextToken: true)
    }
}
