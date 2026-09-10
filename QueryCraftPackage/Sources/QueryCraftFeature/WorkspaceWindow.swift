import AppKit

@MainActor
final class WorkspaceWindow: NSWindow {
    func closeAfterApproval() {
        close()
    }
}
