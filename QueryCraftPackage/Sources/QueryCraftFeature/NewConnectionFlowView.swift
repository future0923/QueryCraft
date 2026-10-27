import SwiftUI

struct NewConnectionFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: NewConnectionFlowModel
    @State private var sshDraft: SSHConnectionDraft?
    @State private var installRequestID: UUID?
    @State private var uninstallRequestID: UUID?
    @State private var isShowingInstallConfirmation = false
    @State private var isShowingUninstallConfirmation = false

    let welcomeModel: WelcomeModel
    let initialGroupID: ConnectionGroup.ID?

    init(
        welcomeModel: WelcomeModel,
        initialGroupID: ConnectionGroup.ID?,
        driverManager: DatabaseDriverManager = .shared
    ) {
        self.welcomeModel = welcomeModel
        self.initialGroupID = initialGroupID
        _model = State(
            initialValue: NewConnectionFlowModel(
                driverManager: driverManager, allowsSSH: welcomeModel.ssh != nil
            )
        )
    }

    var body: some View {
        switch model.step {
        case .selectDatabase:
            DatabaseDriverSelectionView(
                model: model,
                cancel: dismiss.callAsFunction,
                continueSelection: continueSelection,
                uninstallSelection: requestUninstall
            )
            .task {
                await model.loadCatalog()
            }
            .task(id: installRequestID) {
                guard installRequestID != nil else { return }
                await model.continueWithSelection()
                installRequestID = nil
            }
            .task(id: uninstallRequestID) {
                guard uninstallRequestID != nil else { return }
                await model.uninstallSelection()
                uninstallRequestID = nil
            }
            .alert(
                AppCopy.current.text("驱动未安装", "Driver Not Installed"),
                isPresented: $isShowingInstallConfirmation,
                presenting: model.selectedPlugin
            ) { _ in
                Button(
                    AppCopy.current.text("安装", "Install"),
                    action: startInstallation
                )
                .accessibilityIdentifier("confirmDriverInstallationButton")
                .keyboardShortcut(.defaultAction)
                Button(
                    AppCopy.current.text("取消", "Cancel"),
                    role: .cancel
                ) {}
            } message: { item in
                Text(
                    AppCopy.current.text(
                        "\(item.displayName) 驱动尚未安装。是否从驱动市场下载？",
                        "The \(item.displayName) driver is not installed. Download it from the Driver Marketplace?"
                    )
                )
            }
            .alert(
                AppCopy.current.text("卸载驱动？", "Uninstall Driver?"),
                isPresented: $isShowingUninstallConfirmation,
                presenting: model.selectedPlugin
            ) { _ in
                Button(
                    AppCopy.current.text("卸载", "Uninstall"),
                    role: .destructive,
                    action: startUninstall
                )
                .accessibilityIdentifier("confirmDriverUninstallButton")
                Button(
                    AppCopy.current.text("取消", "Cancel"),
                    role: .cancel
                ) {}
            } message: { item in
                Text(
                    AppCopy.current.text(
                        "将从这台 Mac 移除 \(item.displayName) 驱动。连接配置不会被删除。请先关闭正在使用此驱动的工作区。",
                        "The \(item.displayName) driver will be removed from this Mac. Connection profiles will be kept. Close workspaces using this driver first."
                    )
                )
            }
            .alert(
                AppCopy.current.text(
                    "驱动操作失败",
                    "Driver Operation Failed"
                ),
                isPresented: $model.isShowingInstallationError
            ) { } message: {
                Text(model.installationErrorMessage)
            }
        case .configureSSH:
            if let ssh = welcomeModel.ssh, let sshDraft {
                SSHConnectionEditor(draft: sshDraft, service: ssh.service)
            }
        case .configure(let databaseProduct):
            CreateConnectionView(
                model: welcomeModel,
                initialGroupID: initialGroupID,
                databaseProduct: databaseProduct
            )
        }
    }

    private func continueSelection() {
        if model.selectsSSH, let ssh = welcomeModel.ssh {
            sshDraft = SSHConnectionDraft(policy: ssh.policy)
            sshDraft?.groupID = initialGroupID
        }
        guard let item = model.selectedPlugin else { return }
        switch item.installationState {
        case .installed, .updateAvailable, .updateReady, .updating:
            installRequestID = UUID()
        case .notInstalled, .failed:
            isShowingInstallConfirmation = true
        case .installing:
            break
        case .uninstalling:
            break
        }
    }

    private func startInstallation() {
        installRequestID = UUID()
    }

    private func requestUninstall() {
        guard model.selectedPlugin?.installationState.hasInstalledDriver == true else {
            return
        }
        isShowingUninstallConfirmation = true
    }

    private func startUninstall() {
        uninstallRequestID = UUID()
    }
}

#Preview {
    NewConnectionFlowView(
        welcomeModel: WelcomeModel(
            repository: InMemoryConnectionProfileRepository(),
            credentialStore: InMemoryCredentialStore(),
            connectionTester: InMemoryConnectionTester()
        ),
        initialGroupID: nil
    )
}
