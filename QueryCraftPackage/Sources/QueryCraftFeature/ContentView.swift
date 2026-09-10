import AppKit
import SwiftUI

public struct ContentView: View {
    @FocusState private var focusedAction: WelcomeAction?
    @State private var isPresentingNewConnectionFlow = false
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
            await loadWelcomeState()
        }
        .onAppear {
            focusedAction = .createConnection
        }
    }

    public init() {
        _model = State(initialValue: WelcomeModel.makeDefault())
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
