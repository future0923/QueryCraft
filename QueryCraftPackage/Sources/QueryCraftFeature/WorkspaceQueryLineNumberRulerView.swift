import AppKit

final class WorkspaceQueryLineNumberRulerView: NSRulerView {
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        ),
        .foregroundColor: NSColor.tertiaryLabelColor,
    ]

    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        needsDisplay = true

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(invalidateDisplay),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
        center.addObserver(
            self,
            selector: #selector(invalidateDisplay),
            name: NSText.didChangeNotification,
            object: textView
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func invalidateDisplay() {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard
            let textView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer,
            let scrollView = textView.enclosingScrollView
        else {
            return
        }

        NSColor.controlBackgroundColor.setFill()
        rect.fill()

        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect,
            in: textContainer
        )
        let source = textView.string as NSString
        let firstCharacter = layoutManager.characterIndexForGlyph(
            at: glyphRange.location
        )
        var lineNumber = 1
        if firstCharacter > 0 {
            lineNumber += source.substring(to: firstCharacter)
                .filter { $0 == "\n" }
                .count
        }

        layoutManager.enumerateLineFragments(
            forGlyphRange: glyphRange
        ) { _, usedRect, _, fragmentGlyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(
                at: fragmentGlyphRange.location
            )
            let startsLogicalLine = characterIndex == 0
                || source.character(at: characterIndex - 1) == 10
            guard startsLogicalLine else { return }

            let value = String(lineNumber) as NSString
            let size = value.size(withAttributes: Self.attributes)
            let origin = textView.textContainerOrigin
            let y = usedRect.minY + origin.y - visibleRect.minY
            value.draw(
                at: NSPoint(
                    x: self.ruleThickness - size.width - 8,
                    y: y
                ),
                withAttributes: Self.attributes
            )
            lineNumber += 1
        }
    }
}
