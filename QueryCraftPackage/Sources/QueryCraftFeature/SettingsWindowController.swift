import AppKit
import SwiftUI

final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

@MainActor
public final class SettingsWindowController: NSWindowController,
    NSWindowDelegate
{
    private static var shared: SettingsWindowController?

    private let navigation = SettingsNavigation()

    public static func show() {
        if shared == nil {
            shared = SettingsWindowController()
        }
        shared?.showWindow(nil)
    }

    private init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 730, height: 780),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController does not support NSCoder")
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = ApplicationPreferences.shared.settingsWindowTitle
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 500)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                navigation: navigation,
                updateWindowTitle: { [weak window] title in
                    window?.title = title
                }
            )
        )
        window.setContentSize(NSSize(width: 730, height: 780))
        window.setFrameAutosaveName("QueryCraftSettingsWindow.v4")
        window.center()
    }
}
