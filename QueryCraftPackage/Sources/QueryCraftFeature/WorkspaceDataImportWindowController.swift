import AppKit
import SwiftUI

@MainActor
final class WorkspaceDataImportWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [String: WorkspaceDataImportWindowController] = [:]
    private let key: String
    private let model: WorkspaceDataImportModel

    static func show(key: String, model: @autoclosure () -> WorkspaceDataImportModel) {
        if let existing = windows[key] {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return
        }
        let controller = WorkspaceDataImportWindowController(key: key, model: model())
        windows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private init(key: String, model: WorkspaceDataImportModel) {
        self.key = key; self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppCopy.current.text("导入表数据", "Import Table Data")
        window.contentMinSize = NSSize(width: 760, height: 580)
        window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        let host = NSHostingController(rootView: WorkspaceDataImportView(model: model) { [weak self] in self?.window?.performClose(nil) })
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 24, dy: 24)
            window.setContentSize(NSSize(width: min(960, visible.width), height: min(720, visible.height - 32)))
        }
        window.center()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.isRunning }
    func windowWillClose(_ notification: Notification) {
        model.close()
        if Self.windows[key] === self { Self.windows[key] = nil }
    }
}
