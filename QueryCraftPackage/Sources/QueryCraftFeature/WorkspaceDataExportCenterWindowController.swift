import AppKit
import SwiftUI

@MainActor
final class WorkspaceDataExportCenterWindowController: NSWindowController,
    NSWindowDelegate
{
    private static var shared: WorkspaceDataExportCenterWindowController?

    static func show() {
        if shared == nil {
            shared = WorkspaceDataExportCenterWindowController()
        }
        shared?.window?.title = AppCopy.current.text(
            "导出中心",
            "Export Center"
        )
        shared?.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 280),
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
        window.title = AppCopy.current.text("导出中心", "Export Center")
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 220)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: WorkspaceDataExportCenterView(
                manager: .shared
            )
        )
        window.setFrameAutosaveName("QueryCraftExportCenterWindow.v2")
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceDataExportCenterWindowController does not support NSCoder")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
