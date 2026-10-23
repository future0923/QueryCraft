import Foundation

/// Platform adapters must reject stale or composing input before replacing text.
enum SQLCompletionApplication {
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
}
