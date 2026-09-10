import SwiftUI

struct DatabaseDriverSelectionFooter: View {
    let model: NewConnectionFlowModel
    let cancel: () -> Void
    let continueSelection: () -> Void
    let uninstallSelection: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if !model.installationErrorMessage.isEmpty {
                Label(
                    model.installationErrorMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("databaseDriverInstallError")
            }

            HStack {
                if model.selectedItem?.installationState.hasInstalledDriver == true {
                    Button(
                        AppCopy.current.text("卸载驱动", "Uninstall Driver"),
                        systemImage: "trash",
                        role: .destructive,
                        action: uninstallSelection
                    )
                    .disabled(model.isInstalling)
                    .accessibilityIdentifier("uninstallDatabaseDriverButton")
                }
                Spacer()
                Button(
                    AppCopy.current.text("取消", "Cancel"),
                    action: cancel
                )
                .keyboardShortcut(.cancelAction)
                Button(continueButtonTitle, action: continueSelection)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedItem == nil || model.isInstalling)
                    .accessibilityIdentifier("continueDatabaseSelectionButton")
            }
        }
        .padding(20)
    }

    private var continueButtonTitle: String {
        guard let selectedItem = model.selectedItem else {
            return AppCopy.current.text("继续", "Continue")
        }
        switch selectedItem.installationState {
        case .installed, .updateAvailable, .updateReady:
            return AppCopy.current.text("继续", "Continue")
        case .notInstalled, .failed:
            return AppCopy.current.text("下载并继续", "Download and Continue")
        case .installing, .updating:
            return AppCopy.current.text("正在安装", "Installing")
        case .uninstalling:
            return AppCopy.current.text("正在卸载", "Uninstalling")
        }
    }
}
