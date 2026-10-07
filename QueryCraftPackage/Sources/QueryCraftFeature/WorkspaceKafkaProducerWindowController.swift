import AppKit
import SwiftUI

@MainActor
final class WorkspaceKafkaProducerWindowController: NSWindowController, NSWindowDelegate {
    private struct Identifier: Hashable {
        let workspace: ObjectIdentifier
        let topic: String
        var draftID: UUID? = nil
    }
    private static var windows: [Identifier: WorkspaceKafkaProducerWindowController] = [:]
    private let identifier: Identifier
    private let editor: WorkspaceKafkaProducerModel

    static func show(topic: String, workspace: WorkspaceModel, copying source: WorkspaceKafkaMessageReference? = nil) {
        let identifier = Identifier(workspace: ObjectIdentifier(workspace), topic: topic)
        if source == nil, let existing = windows[identifier] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let parent = NSApp.keyWindow
        let controller = WorkspaceKafkaProducerWindowController(topic: topic, workspace: workspace, copying: source)
        windows[controller.identifier] = controller
        controller.position(relativeTo: parent)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init(topic: String, workspace: WorkspaceModel, copying source: WorkspaceKafkaMessageReference? = nil) {
        identifier = Identifier(workspace: ObjectIdentifier(workspace), topic: topic, draftID: source == nil ? nil : UUID())
        editor = WorkspaceKafkaProducerModel(topic: topic, source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppCopy.current.text("发送消息", "Send Message") + " · " + topic
        if let source { window.title += " · \(source.partition):\(source.offset)" }
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        let host = NSHostingController(rootView: WorkspaceKafkaProducerSheet(workspace: workspace, editor: editor) { [weak self] in
            self?.window?.performClose(nil)
        })
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(NSSize(width: 980, height: 700))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func position(relativeTo parent: NSWindow?) {
        guard let window, let screen = parent?.screen ?? NSScreen.main else { window?.center(); return }
        let available = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        let maximum = window.contentRect(forFrameRect: available).size
        window.setContentSize(NSSize(width: min(980, maximum.width), height: min(700, maximum.height)))
        let anchor = parent?.frame ?? available
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: min(max(anchor.midX - size.width / 2, available.minX), available.maxX - size.width),
            y: min(max(anchor.midY - size.height / 2, available.minY), available.maxY - size.height)))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !editor.isSending }

    func windowWillClose(_ notification: Notification) {
        if Self.windows[identifier] === self { Self.windows[identifier] = nil }
    }
}
