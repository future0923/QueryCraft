import AppKit

@MainActor
final class WorkspaceRedisCommandNativeTextField: NSTextField {
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

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        configureCurrentEditor()
        return true
    }

    func configureCurrentEditor() {
        (currentEditor() as? NSTextView)?.configureForCodeInput()
    }

    private func scheduleFocus() {
        guard window != nil,
              isEditable,
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
        guard let window,
              isEditable,
              requestedFocusRequest != appliedFocusRequest,
              window.makeFirstResponder(self)
        else { return }

        configureCurrentEditor()
        appliedFocusRequest = requestedFocusRequest
        currentEditor()?.selectedRange = NSRange(
            location: stringValue.utf16.count,
            length: 0
        )
    }
}
