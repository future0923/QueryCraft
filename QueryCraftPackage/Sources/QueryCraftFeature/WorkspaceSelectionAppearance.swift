import AppKit

@MainActor
enum WorkspaceSelectionAppearance {
    static var backgroundColor: NSColor {
        .unemphasizedSelectedContentBackgroundColor
    }
}
