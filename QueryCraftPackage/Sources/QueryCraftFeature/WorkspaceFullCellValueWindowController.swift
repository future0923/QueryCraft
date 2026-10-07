import AppKit
import SwiftUI

@MainActor
final class WorkspaceFullCellValueWindowController: NSWindowController, NSWindowDelegate {
    private static let defaultSize = NSSize(width: 1280, height: 800)
    private static let minimumSize = NSSize(width: 560, height: 360)
    private static let screenMargin: CGFloat = 24

    var onClose: (() -> Void)?

    init(text: String, title: String) {
        let content = WorkspaceReadOnlyTextView(
            text: text,
            usesMonospacedFont: false,
            accessibilityLabel: title,
            showsBorder: false,
            presentation: .automaticJSON,
            usesEditorFont: true
        )
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.defaultSize.width,
                height: Self.defaultSize.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceFullCellValueWindowController does not support NSCoder")
    }

    func show(relativeTo _: NSRect, of view: NSView) {
        guard let window else { return }

        let visibleFrame = (view.window?.screen ?? NSScreen.main)?.visibleFrame
            ?? window.screen?.visibleFrame
        if let visibleFrame {
            let availableFrame = visibleFrame.insetBy(
                dx: Self.screenMargin,
                dy: Self.screenMargin
            )
            let availableContentSize = window.contentRect(
                forFrameRect: availableFrame
            ).size
            let contentSize = NSSize(
                width: min(Self.defaultSize.width, availableContentSize.width),
                height: min(Self.defaultSize.height, availableContentSize.height)
            )
            window.setContentSize(contentSize)

            let size = window.frame.size
            let x = min(
                max(visibleFrame.midX - size.width / 2, availableFrame.minX),
                availableFrame.maxX - size.width
            )
            let y = min(
                max(visibleFrame.midY - size.height / 2, availableFrame.minY),
                availableFrame.maxY - size.height
            )
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
