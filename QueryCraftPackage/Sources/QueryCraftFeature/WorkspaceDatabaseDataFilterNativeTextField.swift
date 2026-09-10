import AppKit

@MainActor
final class WorkspaceDatabaseDataFilterNativeTextField: NSTextField {
    private var requestedFocusRequest = 0
    private var appliedFocusRequest = 0
    private var isFocusScheduled = false

    func requestFocus(_ request: Int) {
        guard request > 0, request != appliedFocusRequest else { return }
        requestedFocusRequest = request
        scheduleFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFocus()
    }

    private func scheduleFocus() {
        guard window != nil,
              requestedFocusRequest > 0,
              requestedFocusRequest != appliedFocusRequest,
              !isFocusScheduled
        else { return }

        isFocusScheduled = true
        RunLoop.main.perform(
            #selector(applyScheduledFocus),
            target: self,
            argument: nil,
            order: 0,
            modes: [.default]
        )
    }

    @objc private func applyScheduledFocus() {
        isFocusScheduled = false
        applyRequestedFocus()
    }

    private func applyRequestedFocus() {
        guard let window,
              requestedFocusRequest > 0,
              requestedFocusRequest != appliedFocusRequest,
              window.makeFirstResponder(self)
        else { return }

        appliedFocusRequest = requestedFocusRequest
        currentEditor()?.selectedRange = NSRange(
            location: stringValue.utf16.count,
            length: 0
        )
    }
}
