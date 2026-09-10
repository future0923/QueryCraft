import AppKit

@MainActor
protocol WorkspaceCredentialPrompting: AnyObject {
    func requestPassword(
        for profile: ConnectionProfile,
        attachedTo window: NSWindow?
    ) async -> String?
}

@MainActor
final class NativeWorkspaceCredentialPrompter: WorkspaceCredentialPrompting {
    func requestPassword(
        for profile: ConnectionProfile,
        attachedTo window: NSWindow?
    ) async -> String? {
        let copy = AppCopy.current
        let alert = NSAlert()
        alert.messageText = copy.workspaceCredentialPromptTitle
        alert.informativeText = copy.workspaceCredentialPromptMessage(
            profileName: profile.name,
            username: profile.username,
            host: profile.host
        )
        alert.alertStyle = .informational

        let passwordField = NSSecureTextField(
            frame: NSRect(x: 0, y: 0, width: 320, height: 24)
        )
        passwordField.placeholderString = copy.password
        passwordField.setAccessibilityLabel(copy.password)
        alert.accessoryView = passwordField

        let connectButton = alert.addButton(
            withTitle: copy.connect
        )
        let cancelButton = alert.addButton(
            withTitle: copy.cancel
        )
        connectButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = passwordField

        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { result in
                    continuation.resume(returning: result)
                }
            }
        } else {
            response = alert.runModal()
        }

        guard response == .alertFirstButtonReturn else { return nil }
        return passwordField.stringValue
    }
}
