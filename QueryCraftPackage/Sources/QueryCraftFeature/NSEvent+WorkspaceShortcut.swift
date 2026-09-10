import AppKit

extension NSEvent {
    func matchesWorkspaceShortcut(
        keyCode: UInt16,
        character: String
    ) -> Bool {
        self.keyCode == keyCode
            || charactersIgnoringModifiers?.lowercased() == character
    }
}
