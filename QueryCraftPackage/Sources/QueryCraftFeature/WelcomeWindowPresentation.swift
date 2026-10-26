import AppKit

/// AppKit-hosted settings windows do not inherit a SwiftUI scene's OpenWindowAction.
/// Ask the application delegate to reveal/reuse the real welcome connection window.
@MainActor public enum WelcomeWindowPresentation {
    public static let windowIdentifier = NSUserInterfaceItemIdentifier("querycraft-welcome")
    public static let requestNotification = Notification.Name("QueryCraft.showConnectionCatalog")
    public static func show() { NotificationCenter.default.post(name: requestNotification, object: nil) }
}
