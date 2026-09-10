import SwiftUI

struct ConnectionProfileDriverInstallationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ConnectionProfileDriverInstallationModel
    @State private var installationRequestID: UUID?

    private let openProfile: () -> Void

    init(
        profile: ConnectionProfile,
        driverManager: DatabaseDriverManager = .shared,
        openProfile: @escaping () -> Void
    ) {
        _model = State(
            initialValue: ConnectionProfileDriverInstallationModel(
                profile: profile,
                driverManager: driverManager
            )
        )
        self.openProfile = openProfile
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(24)

            Divider()

            installationContent
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 116)

            Divider()

            footer
                .padding(16)
        }
        .frame(width: 500)
        .interactiveDismissDisabled(
            model.installationState?.isBusy == true
        )
        .accessibilityIdentifier("connectionProfileDriverInstallationSheet")
        .task {
            if await model.prepare() {
                completeInstallation()
            }
        }
        .task(id: installationRequestID) {
            guard installationRequestID != nil else { return }
            if await model.install() {
                completeInstallation()
            }
            installationRequestID = nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            DatabaseBrandIcon(
                databaseProduct: model.profile.databaseProduct
            )
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                Text(
                    AppCopy.current.text(
                        "需要安装 \(model.profile.databaseType.title) 驱动",
                        "\(model.profile.databaseType.title) Driver Required"
                    )
                )
                .font(.title2)
                .bold()

                Text(
                    AppCopy.current.text(
                        "打开连接“\(model.profile.name)”需要先安装此驱动。",
                        "Install this driver before opening “\(model.profile.name)”."
                    )
                )
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var installationContent: some View {
        if model.isLoading {
            ProgressView(
                AppCopy.current.text(
                    "正在检查驱动...",
                    "Checking driver..."
                )
            )
            .controlSize(.small)
        } else if let item = model.catalogItem {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.entry.displayName)
                            .font(.headline)
                        if let metadata = metadata(for: item) {
                            Text(metadata)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    DatabaseDriverInstallationStatusView(
                        state: item.installationState
                    )
                }

                if !model.errorMessage.isEmpty {
                    Label(
                        model.errorMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "connectionProfileDriverInstallationError"
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button(
                AppCopy.current.text("取消", "Cancel"),
                role: .cancel,
                action: dismiss.callAsFunction
            )
            .disabled(model.installationState?.isBusy == true)
            .keyboardShortcut(.cancelAction)

            Button(
                installButtonTitle,
                action: startInstallation
            )
            .disabled(model.isBusy || model.catalogItem == nil)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("installDriverAndOpenProfileButton")
        }
    }

    private var installButtonTitle: String {
        if case .failed = model.installationState {
            return AppCopy.current.text("重试", "Retry")
        }
        return AppCopy.current.text("安装并打开", "Install and Open")
    }

    private func metadata(for item: DatabaseDriverCatalogItem) -> String? {
        var components: [String] = []
        if let version = item.availableVersion {
            components.append(
                AppCopy.current.text(
                    "版本 \(version)",
                    "Version \(version)"
                )
            )
        }
        if let downloadSize = item.downloadSize {
            components.append(downloadSize.formatted(.byteCount(style: .file)))
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private func startInstallation() {
        installationRequestID = UUID()
    }

    private func completeInstallation() {
        dismiss()
        openProfile()
    }
}
