import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class SSHTerminalWorkspace {
    let accounts: SSHSettingsModel
    let scripts: ShellScriptSettingsModel
    var scriptDispatching = false
    @ObservationIgnored private var scriptDispatch: Task<Void, Never>?
    @ObservationIgnored private var scriptDispatchGeneration = 0
    var inspectorTab: SSHTerminalInspectorTab = .scripts
    var sessions: [SSHTerminalSession] = []
    var selection: UUID?
    var selectedServer: UUID?
    var error: String?
    var editingConnection: SSHConnectionDraft?
    var showsSidebar: Bool { didSet { preferences.set(showsSidebar, forKey: "QueryCraftSSHTerminal.showsSidebar") } }
    var showsInspector: Bool { didSet { preferences.set(showsInspector, forKey: "QueryCraftSSHTerminal.showsInspector") } }
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var sidebarRevision = 0
    @ObservationIgnored private var inspectorRevision = 0
    init(service: SSHConnectionService = SSHConnectionService(), preferences: UserDefaults? = nil) {
        let preferences = preferences ?? .standard
        self.preferences = preferences
        showsSidebar = preferences.object(forKey: "QueryCraftSSHTerminal.showsSidebar") as? Bool ?? true
        showsInspector = preferences.object(forKey: "QueryCraftSSHTerminal.showsInspector") as? Bool ?? true
        accounts = SSHSettingsModel(service: service)
        scripts = ShellScriptSettingsModel(service: ShellScriptLibraryService(directory: service.directory))
    }
    var selectedProfile: SSHConnection? { accounts.profiles.first { $0.id == selectedServer } }
    var inspectedProfile: SSHConnection? { current?.profile ?? selectedProfile }
    private func cancelScriptDispatch() {
        scriptDispatchGeneration &+= 1; scriptDispatch?.cancel(); scriptDispatch = nil; scriptDispatching = false
        scripts.status = ""; scripts.actionError = nil
    }
    func useScript(_ record: ShellScript, execute: Bool) {
        guard !scriptDispatching, let session = current, session.state == .connected else { return }
        scriptDispatchGeneration &+= 1; let generation = scriptDispatchGeneration
        scriptDispatching = true; scripts.actionError = nil; scripts.status = ""
        scriptDispatch = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.scriptDispatchGeneration == generation { self.scriptDispatching = false; self.scriptDispatch = nil }
            }
            guard let script = await self.scripts.current(record, requireRevision: true) else { return }
            do {
                let endpoints = session.endpoints.isEmpty ? [session.profile] : session.endpoints
                try await self.accounts.service.validateTerminalScript(script, endpoints: endpoints)
                try Task.checkCancellation()
                guard self.scriptDispatchGeneration == generation, self.current === session, session.state == .connected else { return }
                try session.insertScript(script.script, execute: execute)
                self.scripts.status = execute
                    ? AppCopy.current.text("已发送到当前终端执行。", "Sent to the current terminal.")
                    : AppCopy.current.text("已填入当前终端，按回车执行。", "Inserted in the terminal. Press Return to run.")
            } catch is CancellationError {} catch {
                if self.scriptDispatchGeneration == generation { self.scripts.actionError = error.localizedDescription }
            }
        }
    }
    func setSidebarVisible(_ value: Bool) { sidebarRevision &+= 1; if showsSidebar != value { showsSidebar = value } }
    func setInspectorVisible(_ value: Bool) { inspectorRevision &+= 1; if showsInspector != value { showsInspector = value } }
    // Native split callbacks may arrive while SwiftUI is updating its hosted views.
    // Defer observation writes; a newer explicit toggle supersedes a pending callback.
    func sidebarVisibilityChanged(_ value: Bool) {
        sidebarRevision &+= 1; let revision = sidebarRevision
        Task { @MainActor [weak self] in
            guard let self, self.sidebarRevision == revision else { return }
            self.setSidebarVisible(value)
        }
    }
    func inspectorVisibilityChanged(_ value: Bool) {
        inspectorRevision &+= 1; let revision = inspectorRevision
        Task { @MainActor [weak self] in
            guard let self, self.inspectorRevision == revision else { return }
            self.setInspectorVisible(value)
        }
    }
    func toggleSidebar() { setSidebarVisible(!showsSidebar) }
    func toggleInspector() { setInspectorVisible(!showsInspector) }
    func selectServer(_ id: UUID?) {
        selectedServer = id
        selection = sessions.last(where: { $0.profile.id == id && $0.isActive })?.id
            ?? sessions.last(where: { $0.profile.id == id })?.id
        cancelScriptDispatch()
    }
    func selectSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        selection = session.id; selectedServer = session.profile.id
        cancelScriptDispatch()
    }
    func addServer() { editingConnection = SSHConnectionDraft(policy: accounts.policy) }
    func editServer(_ profile: SSHConnection) {
        guard let current = accounts.profiles.first(where: { $0.id == profile.id }) else { return }
        editingConnection = SSHConnectionDraft(profile: current, policy: accounts.policy)
    }
    var current: SSHTerminalSession? { sessions.first { $0.id == selection } }
    var hasActiveSessions: Bool { sessions.contains(where: \.isActive) }
    func openConnection(_ profile: SSHConnection) {
        if let existing = sessions.last(where: { $0.profile.id == profile.id && $0.isActive }) {
            selectSession(existing.id)
        } else {
            // The caller already has the saved account. Do not wait for the sidebar reload:
            // its busy guard can return before the initial snapshot is available.
            // Session.start validates the saved account and route again before authentication.
            connect(profile)
        }
    }
    func connect(_ profile: SSHConnection) {
        guard sessions.count < 12 else { error = AppCopy.current.text("最多打开 12 个终端，请先关闭不需要的页签。", "Close an unused tab before opening more than 12 terminals."); return }
        error = nil; selectedServer = profile.id
        let session = SSHTerminalSession(profile: profile)
        sessions.append(session); selection = session.id
        cancelScriptDispatch()
        session.start(service: accounts.service)
    }
    func close(_ session: SSHTerminalSession) {
        session.disconnect()
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        if selection == session.id {
            selection = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
            if let current { selectedServer = current.profile.id }
        }
        cancelScriptDispatch()
    }
    func reconnect(_ session: SSHTerminalSession) {
        guard !session.isActive, let latest = accounts.profiles.first(where: { $0.id == session.profile.id }) else { return }
        close(session); connect(latest)
    }
    func disconnectAll() { cancelScriptDispatch(); for session in sessions { session.disconnect() } }
    func reload() async {
        await accounts.load()
        guard accounts.loaded, accounts.error == nil else { return }
        for session in sessions where session.isActive {
            let original = session.endpoints.isEmpty ? [session.profile] : session.endpoints
            if original.contains(where: { endpoint in accounts.profiles.first(where: { $0.id == endpoint.id }) != endpoint }) {
                session.disconnect(); session.message = AppCopy.current.text("账号配置已修改或移除，连接已断开。", "The account changed or was removed. Connection closed.")
            }
        }
    }
}

struct SSHTerminalWorkspaceView: View {
    @Bindable var model: SSHTerminalWorkspace
    @State private var closing: SSHTerminalSession?
    private func text(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    var body: some View {
        GeometryReader { geometry in
            WorkspaceMainSplitView(
                showsSidebar: model.showsSidebar, showsInspector: model.showsInspector,
                layoutIdentifier: "QueryCraftSSHTerminalMainSplit",
                onSidebarVisibilityChange: model.sidebarVisibilityChanged,
                onInspectorVisibilityChange: model.inspectorVisibilityChanged,
                sidebarMinimumWidth: 200, sidebarMaximumWidth: 340,
                detailMinimumWidth: 440, inspectorMinimumWidth: 240
            ) {
                serverSidebar
            } detail: {
                terminalColumn
            } inspector: {
                SSHTerminalInspectorView(model: model)
            }
            .frame(width: geometry.size.width, height: geometry.size.height + geometry.safeAreaInsets.top)
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 800, minHeight: 440)
        .focusedSceneValue(\.sshTerminalWorkspace, model)
        .background {
            WorkspaceSidebarKeyCommandHandler(toggleSidebar: model.toggleSidebar, openConnectionPicker: WelcomeWindowPresentation.show)
        }
        .task {
            while !Task.isCancelled {
                await model.reload()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SSHConnectionService.settingsChanged)) { _ in Task { await model.reload() } }
        .sheet(item: $model.editingConnection, onDismiss: { Task { await model.reload() } }) { value in
            SSHConnectionEditor(draft: value, service: model.accounts.service)
        }
        .confirmationDialog(text("关闭这个终端？", "Close this terminal?"), isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), presenting: closing) { session in
            Button(text("断开并关闭", "Disconnect and close"), role: .destructive) { model.close(session); closing = nil }
        } message: { session in Text(text("将断开 \(session.profile.name) 的交互式 Shell。", "Disconnect the interactive shell on \(session.profile.name).")) }
        .accessibilityIdentifier("sshTerminalWorkspace")
    }
    private var serverSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                WorkspaceGridSearchField(text: Binding(get: { model.accounts.search }, set: { model.accounts.search = $0 }),
                    placeholder: text("搜索服务器", "Search servers"), focusRequest: 0, submit: {}, cancel: { model.accounts.search = "" }, accessibilityIdentifier: "sshServerSearch")
                Button(action: model.addServer) { Image(systemName: "plus") }
                    .buttonStyle(.plain).help(text("添加服务器", "Add server")).disabled(!model.accounts.loaded)
            }.controlSize(.regular).padding(.horizontal, 8).padding(.vertical, 6)
            List(selection: Binding(get: { model.selectedServer }, set: { model.selectServer($0) })) {
                Section(text("服务器", "Servers")) {
                    ForEach(model.accounts.filtered) { profile in
                        serverRow(profile).tag(profile.id)
                            .contextMenu {
                                Button(text("在新终端中连接", "Connect in new terminal")) { model.connect(profile) }
                                Button(text("编辑连接…", "Edit connection…")) { model.editServer(profile) }
                            }
                            .onTapGesture(count: 2) { model.connect(profile) }
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            HStack(spacing: 6) {
                Text("\(model.accounts.profiles.count) " + text("台服务器", "servers")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                ProgressView().controlSize(.mini).frame(width: 14, height: 14).opacity(model.accounts.busy ? 1 : 0)
            }.padding(.horizontal, 10).frame(height: 28)
        }.accessibilityIdentifier("sshServerSidebar")
    }
    private var terminalColumn: some View {
        VStack(spacing: 0) {
            if !model.sessions.isEmpty { tabStrip; Divider() }
            if let session = model.current { terminalDetail(session) }
            else { landing }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("sshTerminalColumn")
    }
    private func serverRow(_ profile: SSHConnection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).lineLimit(1)
                Text(profile.username + "@" + profile.host).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if model.sessions.contains(where: { $0.profile.id == profile.id && $0.state == .connected }) {
                Circle().fill(.green).frame(width: 6, height: 6).accessibilityLabel(text("已连接", "Connected"))
            }
        }.padding(.vertical, 4)
    }
    private var tabStrip: some View {
        SSHTerminalTabStrip(sessions: model.sessions, selection: model.selection, select: model.selectSession) { session in
            if session.isActive { closing = session } else { model.close(session) }
        }
        .frame(height: WorkspaceContentTabStripLayout.bandHeight)
    }
    private func terminalDetail(_ session: SSHTerminalSession) -> some View {
        Group {
            if let surface = session.surface { SSHTerminalRepresentable(session: session, surface: surface).id(session.id) }
            else { Color(nsColor: .textBackgroundColor) }
        }
        .overlay(alignment: .center) {
            if session.state == .connecting {
                HStack { ProgressView().controlSize(.small); Text(text("正在建立安全连接…", "Establishing a secure connection…")) }
                    .padding(16).background(.regularMaterial, in: .rect(cornerRadius: 10)).allowsHitTesting(false)
            }
        }
    }
    private var landing: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal").font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
            Text(model.selectedProfile?.name ?? text("SSH 终端", "SSH Terminal")).font(.title2.weight(.semibold))
            Text(model.selectedProfile.map { $0.username + "@" + $0.host + ":" + String($0.port) }
                 ?? text("选择服务器，打开交互式终端。", "Select a server to open an interactive terminal."))
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if let profile = model.selectedProfile {
                Button(text("连接", "Connect"), systemImage: "bolt.horizontal") { model.connect(profile) }.buttonStyle(.borderedProminent)
            } else if model.accounts.loaded && model.accounts.profiles.isEmpty && model.accounts.error == nil {
                Button(text("添加服务器", "Add server"), systemImage: "plus", action: model.addServer)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
    private var statusBar: some View {
        HStack(spacing: 7) {
            if let session = model.current {
                Circle().fill(session.state == .connected ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(session.status)
                if !(model.error ?? session.message).isEmpty { Text(model.error ?? session.message).foregroundStyle(session.state == .failed ? .red : .secondary).lineLimit(1).help(model.error ?? session.message) }
                Spacer(minLength: 6)
                Text(String(session.columns) + " × " + String(session.rows)).monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text(model.error ?? model.accounts.error ?? text("就绪", "Ready")).foregroundStyle(model.error != nil || model.accounts.error != nil ? Color.red : .secondary)
                Spacer()
            }
            if model.accounts.error != nil { Button(text("重试", "Retry")) { Task { await model.reload() } }.buttonStyle(.borderless) }
        }.font(.caption).padding(.horizontal, 10).frame(height: 26)
    }
}

private struct SSHTerminalRepresentable: NSViewRepresentable {
    let session: SSHTerminalSession
    let surface: SSHTerminalSurface
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> NSView { surface.view }
    func makeCoordinator() -> Coordinator { Coordinator() }
    @MainActor final class Coordinator { var focused = false }
    func updateNSView(_ nsView: NSView, context: Context) {
        let view = surface.view
        surface.appearance(dark: colorScheme == .dark)
        if session.state == .connected && !context.coordinator.focused, let window = view.window {
            context.coordinator.focused = true; window.makeFirstResponder(view)
        }
    }
}

@MainActor
public final class SSHTerminalWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SSHTerminalWindowController?
    private let model = SSHTerminalWorkspace()
    private var windowToolbar: SSHTerminalWindowToolbar?
    public static func show() { show(connection: nil) }
    public static func confirmApplicationTermination() -> Bool {
        guard let model = shared?.model, model.hasActiveSessions else { return true }
        let alert = NSAlert()
        alert.messageText = AppCopy.current.text("断开 SSH 连接并退出？", "Disconnect SSH sessions and quit?")
        alert.informativeText = AppCopy.current.text("退出将结束所有交互式 Shell。", "Quitting ends all interactive shells.")
        alert.addButton(withTitle: AppCopy.current.text("断开并退出", "Disconnect and quit"))
        alert.addButton(withTitle: AppCopy.current.text("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        model.disconnectAll(); return true
    }
    static func show(connection: SSHConnection?) {
        if shared == nil { shared = SSHTerminalWindowController() }
        guard let controller = shared else { return }
        if let connection { controller.model.openConnection(connection) }
        controller.showWindow(nil)
    }
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        model.setSidebarVisible(false)
        model.setInspectorVisible(false)
        window.title = AppCopy.current.text("SSH 终端", "SSH Terminal")
        window.minSize = NSSize(width: 960, height: 520); window.isReleasedWhenClosed = false; window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("ssh-workspace")
        window.toolbarStyle = .automatic; window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden; window.titlebarSeparatorStyle = .none
        window.animationBehavior = .none; window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        let toolbar = SSHTerminalWindowToolbar(model: model)
        windowToolbar = toolbar; window.toolbar = toolbar.managedToolbar
        window.contentViewController = NSHostingController(rootView: SSHTerminalWorkspaceView(model: model))
        window.setContentSize(NSSize(width: 1200, height: 780))
        window.setFrameAutosaveName("QueryCraftSSHTerminalWindow.v2"); window.center()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.hasActiveSessions else { return true }
        let alert = NSAlert()
        alert.messageText = AppCopy.current.text("断开所有 SSH 连接？", "Disconnect all SSH sessions?")
        alert.informativeText = AppCopy.current.text("关闭窗口将结束其中的交互式 Shell。", "Closing this window ends its interactive shells.")
        alert.addButton(withTitle: AppCopy.current.text("断开并关闭", "Disconnect and close"))
        alert.addButton(withTitle: AppCopy.current.text("取消", "Cancel"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.model.disconnectAll(); sender.close()
        }
        return false
    }
    public func windowWillClose(_ notification: Notification) { model.disconnectAll(); windowToolbar?.invalidate(); Self.shared = nil }
}

private struct SSHTerminalWorkspaceKey: FocusedValueKey { typealias Value = SSHTerminalWorkspace }
extension FocusedValues {
    var sshTerminalWorkspace: SSHTerminalWorkspace? {
        get { self[SSHTerminalWorkspaceKey.self] }
        set { self[SSHTerminalWorkspaceKey.self] = newValue }
    }
}
