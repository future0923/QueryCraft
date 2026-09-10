import AppKit
import SwiftUI

struct RedisEditableStringTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.configureForCodeInput()
        textView.setAccessibilityLabel(accessibilityLabel)
        scrollView.documentView = textView
        update(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        context.coordinator.parent = self
        update(textView, coordinator: context.coordinator)
    }

    private func update(_ textView: NSTextView, coordinator: Coordinator) {
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            coordinator.isSynchronizing = true
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selectedRange.location, text.utf16.count),
                length: 0
            ))
            coordinator.isSynchronizing = false
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.configureForCodeInput()
        textView.setAccessibilityLabel(accessibilityLabel)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RedisEditableStringTextView
        var isSynchronizing = false

        init(parent: RedisEditableStringTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isSynchronizing,
                  let textView = notification.object as? NSTextView
            else { return }
            parent.text = textView.string
        }
    }
}
