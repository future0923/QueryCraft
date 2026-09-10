import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

/// A native code surface shared by JSON readers and editors. Folding uses layout
/// attachments: the underlying text, selection and clipboard retain hidden text.
struct WorkspaceJSONTextView: NSViewControllerRepresentable {
    @Binding var text: String
    var isEditable = false
    var isRequestPreview = false
    let accessibilityLabel: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var preferences = ApplicationPreferences.shared

    var configuration: SourceEditorConfiguration {
        .init(
            appearance: .init(
                theme: WorkspaceEditorTheme.make(for: colorScheme == .dark ? .darkAqua : .aqua),
                font: preferences.editorFont(),
                wrapLines: true,
                tabWidth: preferences.editorIndentationWidth
            ),
            behavior: .init(
                isEditable: isEditable && isEnabled,
                isSelectable: true,
                indentOption: preferences.editorIndentationStyle == .spaces
                    ? .spaces(count: preferences.editorIndentationWidth) : .tab
            ),
            layout: .init(
                contentInsets: NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 8),
                gutterLeadingPadding: 4,
                gutterMinimumDigitCount: 2
            ),
            peripherals: .init(showGutter: true, showMinimap: false, showFoldingRibbon: true)
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSViewController(context: Context) -> TextViewController {
        let controller = TextViewController(
            string: text,
            language: .json,
            configuration: configuration,
            cursorPositions: [],
            highlightProviders: isRequestPreview
                ? [WorkspaceElasticsearchJSONBodyHighlighter()]
                : [TreeSitterClient()],
            coordinators: [context.coordinator]
        )
        // setText requires the gutter created by loadView. Loading first also
        // makes read-only and selectable behavior available on the first frame.
        controller.loadViewIfNeeded()
        // On macOS 26 an NSView need not clip its descendants by default.
        // The editor's floating gutter and text must stay inside the viewport,
        // including when this controller sits above a sheet's status bar.
        controller.view.clipsToBounds = true
        controller.scrollView.clipsToBounds = true
        controller.textView.setAccessibilityLabel(accessibilityLabel)
        configureFolding(controller)
        return controller
    }

    func updateNSViewController(_ controller: TextViewController, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isSynchronizing = true
        defer { context.coordinator.isSynchronizing = false }
        if controller.text != text {
            controller.setText(text)
        }
        if controller.configuration != configuration {
            controller.configuration = configuration
        }
        controller.textView.setAccessibilityLabel(accessibilityLabel)
        configureFolding(controller)
    }

    private func configureFolding(_ controller: TextViewController) {
        controller.configureFoldingAccessibility(
            actionName: AppCopy.current.text("折叠或展开当前区域", "Collapse or Expand Current Region"),
            hint: AppCopy.current.text("点击折叠或展开 JSON 对象、数组", "Click to collapse or expand a JSON object or array")
        )
    }

    @MainActor
    final class Coordinator: @preconcurrency TextViewCoordinator {
        var text: Binding<String>
        var isSynchronizing = false

        init(text: Binding<String>) { self.text = text }
        func prepareCoordinator(controller: TextViewController) {}

        func textViewDidChangeText(controller: TextViewController) {
            guard !isSynchronizing, controller.isEditable else { return }
            text.wrappedValue = controller.text
        }
    }
}
