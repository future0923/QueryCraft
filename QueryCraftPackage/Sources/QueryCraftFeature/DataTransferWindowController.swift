import AppKit
import SwiftUI

@MainActor
final class DataTransferWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: DataTransferWindowController?
    let model: DataTransferWorkbenchModel

    static func show() {
        if shared == nil { shared = DataTransferWindowController() }
        shared?.window?.title = AppCopy.current.text("数据传输", "Data Transfer")
        shared?.showWindow(nil)
    }

    init(model: DataTransferWorkbenchModel = .init()) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = AppCopy.current.text("数据传输", "Data Transfer")
        window.minSize = NSSize(width: 920, height: 660)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentViewController = NSHostingController(rootView: DataTransferWorkbenchView(model: model))
        window.setFrameAutosaveName("QueryCraftDataTransferWindow.v1"); window.center()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = AppCopy.current.text("保存传输配置？", "Save transfer configuration?")
        alert.informativeText = AppCopy.current.text("关闭窗口不会停止后台传输。", "Closing this window does not stop background transfers.")
        alert.addButton(withTitle: AppCopy.current.text("保存", "Save"))
        alert.addButton(withTitle: AppCopy.current.text("放弃修改", "Discard"))
        alert.addButton(withTitle: AppCopy.current.text("取消", "Cancel"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.model.save(); if self.model.isDirty { return } }
            else if response != .alertSecondButtonReturn { return }
            sender.close()
        }
        return false
    }
    func windowWillClose(_ notification: Notification) { model.close(); Self.shared = nil }
}

public struct WorkspaceToolsCommands: Commands {
    @FocusedValue(\.sshTerminalWorkspace) private var sshWorkspace
    public init() {}
    public var body: some Commands {
        CommandMenu(AppCopy.current.text("工具", "Tools")) {
            Button(AppCopy.current.text("SSH 终端…", "SSH Terminal…"), systemImage: "terminal", action: SSHTerminalWindowController.show)
                .keyboardShortcut("t", modifiers: [.command, .option])
            if let sshWorkspace {
                Button(AppCopy.current.text("新建 SSH 终端", "New SSH Terminal")) {
                    if let profile = sshWorkspace.accounts.profiles.first(where: { $0.id == sshWorkspace.selectedServer }) { sshWorkspace.connect(profile) }
                }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(sshWorkspace.selectedServer == nil)
                Button(AppCopy.current.text("断开当前 SSH 连接", "Disconnect Current SSH Session")) { sshWorkspace.current?.disconnect() }
                    .disabled(sshWorkspace.current?.isActive != true)
                Button(AppCopy.current.text("下一个 SSH 终端", "Next SSH Terminal")) {
                    if let index = sshWorkspace.sessions.firstIndex(where: { $0.id == sshWorkspace.selection }), !sshWorkspace.sessions.isEmpty {
                        let session = sshWorkspace.sessions[(index + 1) % sshWorkspace.sessions.count]
                        sshWorkspace.selection = session.id; sshWorkspace.selectedServer = session.profile.id
                    }
                }.keyboardShortcut(.tab, modifiers: .control).disabled(sshWorkspace.sessions.count < 2)
            }
            Divider()
            Button(AppCopy.current.text("结构对比与同步…", "Schema Comparison and Synchronization…"),
                   systemImage: "arrow.left.arrow.right", action: WorkspaceSchemaComparisonWindowController.show)
                .keyboardShortcut("s", modifiers: [.control, .option, .command])
            Button(AppCopy.current.text("数据传输…", "Data Transfer…"), systemImage: "arrow.left.arrow.right", action: DataTransferWindowController.show)
        }
    }
}

@MainActor
public enum WorkspaceTransferLifecycle {
    public static var hasActiveTransfers: Bool { DataTransferManager.shared.hasActiveRuns }
    public static func cancelAndWait() async { await DataTransferManager.shared.cancelAllAndWait() }
}
