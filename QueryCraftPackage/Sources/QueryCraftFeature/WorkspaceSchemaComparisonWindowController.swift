import AppKit
import SwiftUI

@MainActor
final class WorkspaceSchemaComparisonWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: WorkspaceSchemaComparisonWindowController?
    private let model: WorkspaceSchemaComparisonModel

    static func show() {
        if shared == nil { shared = WorkspaceSchemaComparisonWindowController() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    init(model: WorkspaceSchemaComparisonModel = WorkspaceSchemaComparisonModel(), pasteboard: NSPasteboard = .general,
         makeSavePanel: @escaping () -> NSSavePanel = { NSSavePanel() }) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = AppCopy.current.text("结构对比与同步", "Schema Comparison and Synchronization")
        window.minSize = NSSize(width: 940, height: 612)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.contentViewController = NSHostingController(rootView: WorkspaceSchemaComparisonView(model: model, window: window, pasteboard: pasteboard, makeSavePanel: makeSavePanel))
        window.delegate = self
        window.setFrameAutosaveName("QueryCraftSchemaComparisonWorkflowWindowV3")
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func windowWillClose(_ notification: Notification) {
        model.close()
        Self.shared = nil
    }
}

public struct WorkspaceSchemaComparisonCommands: Commands {
    public init() {}

    public var body: some Commands {
        CommandMenu(AppCopy.current.text("工具", "Tools")) {
            Button(AppCopy.current.text("结构对比与同步…", "Schema Comparison and Synchronization…"),
                   systemImage: "arrow.left.arrow.right", action: WorkspaceSchemaComparisonWindowController.show)
                .keyboardShortcut("s", modifiers: [.control, .option, .command])
        }
    }
}
