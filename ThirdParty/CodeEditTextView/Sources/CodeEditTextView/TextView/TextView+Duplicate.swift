//
//  TextView+Duplicate.swift
//  CodeEditTextView
//

import AppKit

extension TextView {
    /// Duplicates the lines covered by every selection directly below themselves.
    /// A caret duplicates its own line. Carets and selections follow their
    /// duplicated copy so repeated invocations stack copies downwards.
    public func duplicateSelectionOrLine() {
        guard isEditable, !selectionManager.textSelections.isEmpty else { return }

        let source = string as NSString
        let textLength = source.length

        var blocks: [NSRange] = []
        for textSelection in selectionManager.textSelections {
            let range = textSelection.range
            guard range.location != NSNotFound,
                  NSMaxRange(range) <= textLength
            else {
                continue
            }
            let block = source.lineRange(for: range)
            if !blocks.contains(block) {
                blocks.append(block)
            }
        }
        guard !blocks.isEmpty else { return }
        blocks.sort { $0.location < $1.location }

        var edits: [(block: NSRange, insertion: String, earlierLength: Int)] = []
        var earlierTotal = 0
        for block in blocks {
            let blockText = source.substring(with: block)
            // A final line without a trailing newline needs one before its copy.
            let insertion = NSMaxRange(block) == textLength
                && !blockText.hasSuffix("\n")
                ? "\n" + blockText
                : blockText
            edits.append((block, insertion, earlierTotal))
            earlierTotal += (insertion as NSString).length
        }

        undoManager?.beginUndoGrouping()
        for edit in edits.reversed() {
            replaceCharacters(
                in: NSRange(location: NSMaxRange(edit.block), length: 0),
                with: edit.insertion,
                skipUpdateSelection: true
            )
        }
        // Copies of earlier blocks push later carets down by their length.
        for textSelection in selectionManager.textSelections {
            let block = source.lineRange(for: textSelection.range)
            guard let edit = edits.first(where: { $0.block == block }) else {
                continue
            }
            textSelection.range.location += (edit.insertion as NSString).length
                + edit.earlierLength
        }
        selectionManager.notifyAfterEdit(force: true)
        undoManager?.endUndoGrouping()
        scrollSelectionToVisible()
    }
}
