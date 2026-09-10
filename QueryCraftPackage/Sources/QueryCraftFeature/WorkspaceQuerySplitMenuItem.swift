import AppKit

struct WorkspaceQuerySplitMenuItem {
    let title: String
    let keyEquivalent: String
    let keyEquivalentModifierMask: NSEvent.ModifierFlags
    let isEnabled: Bool
    let action: @MainActor @Sendable () -> Void
}
