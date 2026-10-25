import UIKit

/// Visible decorations use public text-input geometry. Accessing layoutManager
/// would switch UIKit's TextKit 2 editor into compatibility mode and break its
/// incremental long-document layout and scrolling.
@MainActor final class MobileEditorDecorations {
    var palette = EditorColorSettings()[.light]
    var mode = EditorColorMode.light
    var isConfigured = false
    private let currentLine = CAShapeLayer()
    private let selection = CAShapeLayer()
    private var numbers: [UILabel] = []
    private var cachedText = ""
    private var lineStarts = [0]
    private weak var attached: UITextView?
    func update(_ view: UITextView) {
        guard isConfigured, view.markedTextRange == nil, view.bounds.width > 0 else { return }
        if attached !== view {
            attached = view
            view.layer.insertSublayer(currentLine, at: 0); view.layer.insertSublayer(selection, at: 1)
        }
        let text = view.text ?? "", length = text.utf16.count
        if cachedText != text {
            cachedText = text; lineStarts = [0]
            let string = text as NSString
            var location = 0
            while location < string.length {
                location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
                let endsWithBreak = string.length > 0 && [0xA, 0xD, 0x85, 0x2028, 0x2029].contains(Int(string.character(at: string.length - 1)))
                if location < string.length || location == string.length && endsWithBreak { lineStarts.append(location) }
            }
        }
        guard let top = view.closestPosition(to: CGPoint(x: view.textContainerInset.left, y: view.bounds.minY)),
              let bottom = view.closestPosition(to: CGPoint(x: view.bounds.maxX, y: view.bounds.maxY)) else { return }
        let first = min(length, max(0, view.offset(from: view.beginningOfDocument, to: top)))
        let last = min(length, max(first, view.offset(from: view.beginningOfDocument, to: bottom)))
        let selected = view.selectedRange
        let activeLine = lineIndex(min(selected.location, length))
        let highlightPath = UIBezierPath(), selectionPath = UIBezierPath()
        var count = 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let firstLine = max(0, lineIndex(first) - 1), lastLine = min(lineStarts.count - 1, lineIndex(last) + 1)
        for line in firstLine...lastLine {
            guard let position = view.position(from: view.beginningOfDocument, offset: lineStarts[line]) else { continue }
            let caret = view.caretRect(for: position)
            guard caret.intersects(view.bounds) else { continue }
            if numbers.count <= count {
                let label = UILabel(); label.textAlignment = .right
                label.isUserInteractionEnabled = false; label.isAccessibilityElement = false
                label.accessibilityIdentifier = "sqlLineNumber"
                label.layer.zPosition = 2 // Stay above the non-view current-line layer.
                view.addSubview(label); numbers.append(label)
            }
            let label = numbers[count], role = line == activeLine ? EditorColorRole.currentLineNumber : .lineNumber
            label.attributedText = NSAttributedString(string: String(line + 1), attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: max(10, (view.font?.pointSize ?? 15) - 2), weight: .regular),
                .foregroundColor: EditorHexColor.color(palette.hex(for: role, mode: mode))])
            view.bringSubviewToFront(label)
            label.contentScaleFactor = view.traitCollection.displayScale
            label.frame = CGRect(x: view.bounds.minX + 2, y: caret.minY, width: 30, height: max(caret.height, label.font.lineHeight))
            label.isHidden = false; count += 1
        }
        for layer in numbers.dropFirst(count) { layer.isHidden = true }
        if let position = view.position(from: view.beginningOfDocument, offset: min(selected.location, length)) {
            let caret = view.caretRect(for: position)
            if caret.intersects(view.bounds) { highlightPath.append(UIBezierPath(rect: CGRect(x: view.bounds.minX, y: caret.minY, width: view.bounds.width, height: caret.height))) }
        }
        if selected.length > 0, NSMaxRange(selected) <= length {
            let clipped = NSIntersectionRange(selected, NSRange(location: first, length: last - first))
            if clipped.length > 0, let start = view.position(from: view.beginningOfDocument, offset: clipped.location),
               let end = view.position(from: start, offset: clipped.length), let range = view.textRange(from: start, to: end) {
                for rect in view.selectionRects(for: range) where rect.rect.width > 0 { selectionPath.append(UIBezierPath(rect: rect.rect)) }
            }
        }
        currentLine.path = highlightPath.cgPath
        currentLine.fillColor = EditorHexColor.color(palette.hex(for: .currentLine, mode: mode)).cgColor
        selection.path = selectionPath.cgPath
        selection.fillColor = EditorHexColor.color(palette.hex(for: .selection, mode: mode)).withAlphaComponent(mode == .dark ? 0.35 : 0.22).cgColor
    }
    private func lineIndex(_ character: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= character { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
}
