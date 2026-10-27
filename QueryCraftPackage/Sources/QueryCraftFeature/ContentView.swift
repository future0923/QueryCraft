import AppKit
import SwiftUI

public struct ContentView: View {
    @FocusState private var focusedAction: WelcomeAction?
    @State private var isPresentingNewConnectionFlow = false
    @State private var sshDraft: SSHConnectionDraft?
    @State private var removingSSH: SSHConnection?
    @State private var profileBeingEdited: ConnectionProfile?
    @State private var initialConnectionGroupID: ConnectionGroup.ID?
    @State private var groupEditorMode: ConnectionGroupEditorMode?
    @State private var deletionRequest: ConnectionDeletionRequest?
    @State private var isShowingDeletionConfirmation = false
    @State private var workspaceRestorationErrorMessage = ""
    @State private var isShowingWorkspaceRestorationError = false
    @State private var driverInstallationRequest:
        ConnectionProfileDriverInstallationRequest?
    @State private var model: WelcomeModel
    private var loadsApplicationState = true

    public var body: some View {
        welcomeView
    }

    private var welcomeView: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 12) {
                        Image(
                            nsImage: NSApplication.shared.applicationIconImage
                        )
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .accessibilityHidden(true)

                        Text("QueryCraft")
                            .font(.largeTitle)
                            .bold()

                        WelcomeLicenseSummaryView()
                    }

                    Color.clear
                        .frame(height: 44)

                    WelcomeActionButton(
                        title: AppCopy.current.text("创建连接", "Create Connection"),
                        systemImage: "plus",
                        isFocused: focusedAction == .createConnection,
                        action: { presentCreateConnection() }
                    )
                    .focused($focusedAction, equals: .createConnection)
                    .frame(maxWidth: 400)
                    .accessibilityIdentifier("createConnectionButton")

                    Spacer()
                }
                .padding(.horizontal, 54)
                .frame(width: primaryPaneWidth(for: geometry.size.width))
                .background {
                    Color.welcomePrimaryPane
                        .ignoresSafeArea()
                }

                Divider()

                ConnectionProfilesPane(
                    model: model,
                    openSSH: { SSHTerminalWindowController.show(connection: $0) },
                    createSSH: { presentSSH() }, editSSH: { presentSSH($0) }, deleteSSH: { removingSSH = $0 },
                    openProfile: openProfile,
                    createProfile: presentCreateConnection,
                    editProfile: presentEditConnection,
                    deleteProfile: prepareProfileDeletion,
                    createGroup: presentCreateGroup,
                    renameGroup: presentRenameGroup,
                    deleteGroup: prepareGroupDeletion
                )
            }
        }
        .frame(
            minWidth: 740,
            maxWidth: .infinity,
            minHeight: 460,
            maxHeight: .infinity
        )
        .sheet(isPresented: $isPresentingNewConnectionFlow) {
            NewConnectionFlowView(
                welcomeModel: model,
                initialGroupID: initialConnectionGroupID
            )
        }
        .sheet(item: $sshDraft, onDismiss: { Task { await model.ssh?.load() } }) { draft in
            if let ssh = model.ssh { SSHConnectionEditor(draft: draft, service: ssh.service) }
        }
        .confirmationDialog(AppCopy.current.text("删除 SSH 连接？", "Delete SSH connection?"), isPresented: Binding(get: { removingSSH != nil }, set: { if !$0 { removingSSH = nil } }), presenting: removingSSH) { profile in
            Button(AppCopy.current.text("删除连接及凭据", "Delete connection and credential"), role: .destructive) {
                removingSSH = nil
                Task { await model.ssh?.remove(profile) }
            }
        } message: { profile in
            Text(AppCopy.current.text("删除“\(profile.name)”的服务器配置、保存的凭据和 MCP 授权。已经运行的远程程序可能继续执行。", "Delete the server account, saved credential and MCP grants for \(profile.name). Already running remote programs may continue."))
        }
        .sheet(item: $profileBeingEdited) { profile in
            CreateConnectionView(
                model: model,
                profile: profile
            )
        }
        .sheet(item: $groupEditorMode) { mode in
            ConnectionGroupEditorView(mode: mode, model: model)
        }
        .sheet(item: $driverInstallationRequest) { request in
            ConnectionProfileDriverInstallationSheet(
                profile: request.profile,
                openProfile: {
                    finishOpeningProfile(request)
                }
            )
        }
        .alert(
            AppCopy.current.text("无法管理连接", "Unable to Manage Connections"),
            isPresented: $model.isShowingLoadError
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(model.loadErrorMessage)
        }
        .alert(
            AppCopy.current.text("无法恢复工作区", "Unable to Restore Workspaces"),
            isPresented: $isShowingWorkspaceRestorationError
        ) { } message: {
            Text(workspaceRestorationErrorMessage)
        }
        .alert(
            deletionRequest?.confirmationTitle
                ?? AppCopy.current.text("删除连接？", "Delete Connection?"),
            isPresented: $isShowingDeletionConfirmation,
            presenting: deletionRequest
        ) { request in
            Button(AppCopy.current.text("删除", "Delete"), role: .destructive) {
                delete(request)
            }
            .keyboardShortcut(.defaultAction)
            Button(
                AppCopy.current.text("取消", "Cancel"),
                role: .cancel
            ) {}
            .keyboardShortcut(.cancelAction)
        } message: { request in
            Text(request.confirmationMessage)
        }
        .task {
            if loadsApplicationState { await loadWelcomeState() } else { await model.loadProfiles() }
        }
        .onReceive(NotificationCenter.default.publisher(for: SSHConnectionService.settingsChanged)) { _ in Task { await model.ssh?.load() } }
        .onAppear {
            focusedAction = .createConnection
        }
    }

    public init() {
        _model = State(initialValue: WelcomeModel.makeDefault())
    }

    init(model: WelcomeModel, loadsApplicationState: Bool = true) {
        _model = State(initialValue: model); self.loadsApplicationState = loadsApplicationState
    }

    private func presentSSH(_ profile: SSHConnection? = nil) {
        guard let ssh = model.ssh else { return }
        sshDraft = SSHConnectionDraft(profile: profile, policy: ssh.policy)
    }

    private func presentCreateConnection(
        in groupID: ConnectionGroup.ID? = nil
    ) {
        profileBeingEdited = nil
        initialConnectionGroupID = groupID
        isPresentingNewConnectionFlow = true
    }

    private func presentEditConnection(_ profile: ConnectionProfile) {
        profileBeingEdited = profile
        initialConnectionGroupID = nil
    }

    private func presentCreateGroup() {
        groupEditorMode = .create
    }

    private func presentRenameGroup(_ group: ConnectionGroup) {
        groupEditorMode = .rename(group)
    }

    private func prepareProfileDeletion(
        _ profile: ConnectionProfile
    ) {
        Task {
            do {
                deletionRequest = try await model.deletionRequest(
                    for: profile
                )
                isShowingDeletionConfirmation = true
            } catch {
                model.present(error)
            }
        }
    }

    private func prepareGroupDeletion(_ group: ConnectionGroup) {
        Task {
            do {
                deletionRequest = try await model.deletionRequest(
                    for: group
                )
                isShowingDeletionConfirmation = true
            } catch {
                model.present(error)
            }
        }
    }

    private func delete(_ request: ConnectionDeletionRequest) {
        Task {
            do {
                try await model.delete(request)
                deletionRequest = nil
            } catch {
                model.present(error)
            }
        }
    }

    private func loadWelcomeState() async {
        ApplicationPreferences.shared.applyApplicationAppearance()
        await DatabaseDriverManager.shared.loadInstalledDrivers()
        if ApplicationPreferences.shared.startupBehavior == .restoreWorkspaces {
            do {
                try await WorkspaceWindowManager.shared.restoreWorkspaces(
                    welcomeWindow: NSApp.keyWindow
                )
            } catch {
                workspaceRestorationErrorMessage = error.localizedDescription
                isShowingWorkspaceRestorationError = true
            }
        }
        await model.loadProfiles()
    }

    private func primaryPaneWidth(for availableWidth: CGFloat) -> CGFloat {
        min(420, max(320, availableWidth * 0.42))
    }

    private func openProfile(_ profile: ConnectionProfile) {
        let welcomeWindow = NSApp.keyWindow
        Task {
            guard await DatabaseDriverManager.shared.isInstalled(
                profile.databaseType
            ) else {
                if driverInstallationRequest == nil {
                    driverInstallationRequest =
                        ConnectionProfileDriverInstallationRequest(
                            profile: profile,
                            welcomeWindow: welcomeWindow
                        )
                }
                return
            }
            await openWorkspace(
                for: profile,
                welcomeWindow: welcomeWindow
            )
        }
    }

    private func finishOpeningProfile(
        _ request: ConnectionProfileDriverInstallationRequest
    ) {
        driverInstallationRequest = nil
        Task {
            await Task.yield()
            await openWorkspace(
                for: request.profile,
                welcomeWindow: request.welcomeWindow
            )
        }
    }

    private func openWorkspace(
        for profile: ConnectionProfile,
        welcomeWindow: NSWindow?
    ) async {
        do {
            try await WorkspaceWindowManager.shared.openWorkspace(
                profileID: profile.id,
                welcomeWindow: welcomeWindow
            )
        } catch {
            model.present(error)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 740, height: 460)
}
