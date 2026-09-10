import AppKit
import SwiftUI

struct WorkspaceReadOnlyTextView: View {
    enum Presentation: Hashable { case plain, json, automaticJSON }

    let text: String
    let usesMonospacedFont: Bool
    let accessibilityLabel: String
    var showsBorder = true
    var presentation: Presentation = .plain

    @State private var formattedText: String?
    @State private var formattedSource: String?
    @State private var worker = WorkspaceJSONPresentationWorker()

    var body: some View {
        Group {
            if presentation == .json || (presentation == .automaticJSON && formattedSource == text && formattedText != nil) {
                WorkspaceJSONTextView(
                    text: .constant(formattedSource == text ? formattedText ?? text : text),
                    accessibilityLabel: accessibilityLabel
                )
                .overlay {
                    if showsBorder {
                        Rectangle().strokeBorder(Color(nsColor: .separatorColor))
                            .allowsHitTesting(false)
                    }
                }
            } else {
                WorkspacePlainReadOnlyTextView(
                    text: text,
                    usesMonospacedFont: usesMonospacedFont,
                    accessibilityLabel: accessibilityLabel,
                    showsBorder: showsBorder
                )
            }
        }
        .task(id: Request(text: text, presentation: presentation)) {
            guard presentation != .plain else { formattedText = nil; return }
            do {
                let result = try await worker.format(text, automatic: presentation == .automaticJSON)
                try Task.checkCancellation()
                formattedText = result
                formattedSource = text
            } catch is CancellationError {
                // Superseded content must never replace the current document.
            } catch {}
        }
    }

    private struct Request: Equatable {
        let text: String
        let presentation: Presentation
    }
}

private struct WorkspacePlainReadOnlyTextView: NSViewRepresentable {
    let text: String
    let usesMonospacedFont: Bool
    let accessibilityLabel: String
    var showsBorder = true

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = showsBorder ? .bezelBorder : .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityLabel(accessibilityLabel)
        scrollView.documentView = textView
        update(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        update(textView)
    }

    private func update(_ textView: NSTextView) {
        if textView.string != text {
            textView.string = text
        }
        textView.font =
            usesMonospacedFont
            ? .monospacedSystemFont(
                ofSize: NSFont.systemFontSize(for: .small),
                weight: .regular
            )
            : .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        textView.setAccessibilityLabel(accessibilityLabel)
    }
}
