import AppKit
import CodeEditSourceEditor
import CodeEditTextView

@MainActor
final class WorkspaceElasticsearchEditorNavigationCoordinator: @preconcurrency TextViewCoordinator {
    private weak var controller: TextViewController?

    func prepareCoordinator(controller: TextViewController) { self.controller = controller }
    func controllerDidAppear(controller: TextViewController) { self.controller = controller }
    func destroy() {}

    func navigate(to range: NSRange) {
        guard let textView = controller?.textView, !textView.hasMarkedText(),
              range.location != NSNotFound, range.location >= 0,
              NSMaxRange(range) <= textView.length else { return }
        textView.window?.makeFirstResponder(textView)
        textView.selectionManager.setSelectedRange(range)
        textView.scrollSelectionToVisible()
    }
}
