import AppKit
import Testing

@testable import QueryCraftFeature

struct SettingsWindowTests {
    @MainActor
    @Test
    func cancelOperationClosesSettingsWindow() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // Match SettingsWindowController: ARC owns the window, so closing it
        // must not also release it through AppKit's legacy ownership policy.
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.orderFront(nil)

        window.cancelOperation(nil)

        #expect(!window.isVisible)
    }
}
