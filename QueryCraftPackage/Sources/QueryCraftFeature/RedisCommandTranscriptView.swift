import AppKit
import SwiftUI

struct RedisCommandTranscriptView: NSViewRepresentable {
    let entries: [RedisCommandTranscriptEntry]
    let revision: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
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
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.setAccessibilityLabel(
            AppCopy.current.text(
                "Redis 命令记录",
                "Redis command transcript"
            )
        )
        textView.setAccessibilityIdentifier("redisCommandTranscript")
        scrollView.documentView = textView
        context.coordinator.render(
            entries: entries,
            revision: revision,
            in: scrollView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.render(
            entries: entries,
            revision: revision,
            in: scrollView
        )
    }

    @MainActor
    final class Coordinator {
        private var renderedRevision = Int.min

        func render(
            entries: [RedisCommandTranscriptEntry],
            revision: Int,
            in scrollView: NSScrollView
        ) {
            guard renderedRevision != revision,
                  let textView = scrollView.documentView as? NSTextView
            else { return }

            let followsTail = renderedRevision == Int.min
                || isNearBottom(scrollView)
            let selectedRange = textView.selectedRange()
            textView.textStorage?.setAttributedString(
                RedisCommandTranscriptAttributedStringBuilder.build(
                    entries: entries
                )
            )
            renderedRevision = revision

            if followsTail {
                textView.scrollToEndOfDocument(nil)
            } else if NSMaxRange(selectedRange) <= textView.string.utf16.count {
                textView.setSelectedRange(selectedRange)
            }
        }

        private func isNearBottom(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return true }
            let remaining = documentView.bounds.maxY
                - scrollView.contentView.bounds.maxY
            return remaining < 48
        }
    }
}
