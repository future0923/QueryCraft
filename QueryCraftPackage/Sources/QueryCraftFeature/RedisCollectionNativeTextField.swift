import AppKit

@MainActor
final class RedisCollectionNativeTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        (currentEditor() as? NSTextView)?.configureForCodeInput()
        return true
    }
}
