import AppKit
import Testing

@testable import QueryCraftFeature

struct SettingsWindowTests {
    @MainActor
    @Test
    func cancelOperationClosesSettingsWindow() {
        let window = SettingsWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // Match the controller's ARC ownership and keep the fixture offscreen.
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.orderBack(nil)

        window.cancelOperation(nil)

        #expect(!window.isVisible)
    }
}
