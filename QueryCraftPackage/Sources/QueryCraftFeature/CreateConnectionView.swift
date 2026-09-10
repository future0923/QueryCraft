import SwiftUI

struct CreateConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: CreateConnectionField?
    @State private var draft = ConnectionProfileDraft()
    @State private var errorMessage = ""
    @State private var isSaving = false
    @State private var connectionTestState = ConnectionTestState.idle
    @State private var testRequestID: UUID?
    @State private var isLoadingCredential: Bool

    let model: WelcomeModel
    let profile: ConnectionProfile?

    init(
        model: WelcomeModel,
        profile: ConnectionProfile? = nil,
        initialGroupID: ConnectionGroup.ID? = nil,
        databaseProduct: DatabaseProduct = .mysql
    ) {
        self.model = model
        self.profile = profile
        var initialDraft = profile.map {
            ConnectionProfileDraft(profile: $0)
        } ?? ConnectionProfileDraft(databaseProduct: databaseProduct)
        if profile == nil {
            initialDraft.groupID = initialGroupID
        }
        _draft = State(initialValue: initialDraft)
        _isLoadingCredential = State(
            initialValue: profile?.storesCredential == true
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(
                profile == nil
                    ? AppCopy.current.text("创建连接", "Create Connection")
                    : AppCopy.current.text("编辑连接", "Edit Connection")
            )
                .font(.title2)
                .bold()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text(AppCopy.current.text("名称", "Name"))
                        .gridColumnAlignment(.trailing)
                    TextField(
                        AppCopy.current.text("连接名称", "Connection name"),
                        text: $draft.name
                    )
                        .focused($focusedField, equals: .name)
                        .accessibilityIdentifier("connectionNameField")
                }

                GridRow {
                    Text(AppCopy.current.text("分组", "Group"))
                    Picker(
                        AppCopy.current.text("分组", "Group"),
                        selection: $draft.groupID
                    ) {
                        Text(AppCopy.current.text("无", "None"))
                            .tag(ConnectionGroup.ID?.none)
                        ForEach(model.groups) { group in
                            Text(group.name)
                                .tag(ConnectionGroup.ID?.some(group.id))
                        }
                    }
                    .labelsHidden()
                    .focused($focusedField, equals: .group)
                    .accessibilityIdentifier("connectionGroupField")
                }

                GridRow {
                    Text(AppCopy.current.text("数据库产品", "Database Product"))
                    HStack(spacing: 8) {
                        DatabaseBrandIcon(
                            databaseProduct: draft.databaseProduct
                        )
                        .frame(width: 22, height: 22)

                        Text(draft.databaseProduct.title)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("connectionDatabaseTypeLabel")
                }

                GridRow {
                    Text(AppCopy.current.text("主机", "Host"))
                    HStack(spacing: 12) {
                        TextField(
                            AppCopy.current.text(
                                "主机名或 IP 地址",
                                "Host name or IP address"
                            ),
                            text: $draft.host
                        )
                            .focused($focusedField, equals: .host)
                            .accessibilityIdentifier("connectionHostField")

                        Text(AppCopy.current.text("端口", "Port"))

                        TextField(
                            AppCopy.current.text("端口", "Port"),
                            value: $draft.port,
                            format: .number.grouping(.never)
                        )
                            .focused($focusedField, equals: .port)
                            .frame(width: 76)
                            .accessibilityIdentifier("connectionPortField")
                    }
                }

                if draft.databaseProduct == .elasticsearch {
                    GridRow {
                        Text(AppCopy.current.text("认证", "Authentication"))
                        Picker(
                            AppCopy.current.text("认证", "Authentication"),
                            selection: $draft.authenticationMethod
                        ) {
                            ForEach(DatabaseConnectionAuthenticationMethod.allCases) { method in
                                Text(method.title).tag(method)
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("connectionAuthenticationPicker")
                    }
                }

                if draft.authenticationMethod == .usernamePassword {
                    GridRow {
                        Text(AppCopy.current.text("用户名", "Username"))
                        TextField(usernamePlaceholder, text: $draft.username)
                            .focused($focusedField, equals: .username)
                            .accessibilityIdentifier("connectionUsernameField")
                    }
                }

                if draft.authenticationMethod != .none {
                    GridRow {
                        Text(credentialFieldTitle)
                        SecureField(
                            credentialFieldPlaceholder,
                            text: $draft.password
                        )
                            .focused($focusedField, equals: .password)
                            .accessibilityIdentifier("connectionPasswordField")
                    }

                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Toggle(saveCredentialTitle, isOn: $draft.savePassword)
                            .accessibilityIdentifier("savePasswordToggle")
                    }
                }

                if draft.databaseProduct != .elasticsearch {
                    GridRow {
                        Text(databaseFieldTitle)
                        TextField(
                            databaseFieldPlaceholder,
                            text: $draft.defaultDatabase
                        )
                            .focused($focusedField, equals: .defaultDatabase)
                            .accessibilityIdentifier("defaultDatabaseField")
                    }
                }

                if draft.databaseProduct != .redis {
                    GridRow {
                        Text("TLS")
                        Picker(
                            AppCopy.current.text("TLS", "TLS"),
                            selection: $draft.tlsMode
                        ) {
                            ForEach(ConnectionTLSMode.allCases) { mode in
                                Text(mode.title)
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("connectionTLSModePicker")
                    }
                }
            }
            .controlSize(.large)
            .disabled(
                connectionTestState.isTesting
                    || isSaving
                    || isLoadingCredential
            )

            if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("connectionFormError")
            }

            switch connectionTestState {
            case .idle:
                EmptyView()
            case .testing:
                Label(
                    AppCopy.current.text("正在测试连接…", "Testing connection..."),
                    systemImage: "network"
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("connectionTestProgress")
            case .succeeded:
                Label(
                    AppCopy.current.text("连接成功。", "Connection successful."),
                    systemImage: "checkmark.circle.fill"
                )
                    .font(.callout)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("connectionTestSuccess")
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("connectionTestFailure")
            }

            Divider()

            HStack {
                Button(
                    AppCopy.current.text("测试连接", "Test Connection"),
                    action: testConnection
                )
                    .disabled(
                        connectionTestState.isTesting
                            || isSaving
                            || isLoadingCredential
                    )
                    .accessibilityIdentifier("testConnectionButton")

                Spacer()

                Button(
                    AppCopy.current.text("取消", "Cancel"),
                    action: dismiss.callAsFunction
                )
                    .keyboardShortcut(.cancelAction)

                Button(AppCopy.current.text("保存", "Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isSaving
                            || connectionTestState.isTesting
                            || isLoadingCredential
                    )
                    .accessibilityIdentifier("saveConnectionButton")
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            focusedField = .name
        }
        .onChange(of: draft) {
            guard !connectionTestState.isTesting else { return }
            connectionTestState = .idle
            errorMessage = ""
        }
        .task(id: testRequestID) {
            guard testRequestID != nil else { return }
            await performConnectionTest()
        }
        .task {
            await loadCredential()
        }
    }

    private func save() {
        errorMessage = ""
        isSaving = true

        Task {
            do {
                if let profile {
                    try await model.updateProfile(profile, from: draft)
                } else {
                    try await model.createProfile(from: draft)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func testConnection() {
        errorMessage = ""
        testRequestID = UUID()
    }

    private func performConnectionTest() async {
        connectionTestState = .testing

        do {
            try await model.testConnection(from: draft)
            try Task.checkCancellation()
            connectionTestState = .succeeded
        } catch is CancellationError {
            connectionTestState = .idle
        } catch {
            connectionTestState = .failed(String(describing: error))
        }
    }

    private func loadCredential() async {
        guard let profile, profile.storesCredential else { return }
        do {
            draft = try await model.draft(for: profile)
            isLoadingCredential = false
        } catch {
            errorMessage = error.localizedDescription
            isLoadingCredential = false
        }
    }

    private var usernamePlaceholder: String {
        if draft.databaseProduct == .redis {
            return AppCopy.current.text(
                "可选的 ACL 用户名",
                "Optional ACL username"
            )
        }
        return AppCopy.current.text(
            "\(draft.databaseProduct.title) 用户名",
            "\(draft.databaseProduct.title) username"
        )
    }

    private var databaseFieldTitle: String {
        draft.databaseProduct == .redis
            ? AppCopy.current.text("逻辑数据库", "Logical Database")
            : AppCopy.current.text("数据库", "Database")
    }

    private var databaseFieldPlaceholder: String {
        draft.databaseProduct == .redis
            ? AppCopy.current.text("例如 DB 0", "For example, DB 0")
            : AppCopy.current.text(
                "可选的默认数据库",
                "Optional default database"
            )
    }

    private var credentialFieldTitle: String {
        draft.authenticationMethod == .apiKey
            ? "API Key"
            : AppCopy.current.text("密码", "Password")
    }

    private var credentialFieldPlaceholder: String {
        draft.authenticationMethod == .apiKey
            ? AppCopy.current.text("Base64 编码的 API Key", "Base64-encoded API Key")
            : AppCopy.current.text("可选", "Optional")
    }

    private var saveCredentialTitle: String {
        draft.authenticationMethod == .apiKey
            ? AppCopy.current.text(
                "将 API Key 存储到钥匙串",
                "Save API Key in Keychain"
            )
            : AppCopy.current.text(
                "将密码存储到钥匙串",
                "Save password in Keychain"
            )
    }
}

#Preview {
    CreateConnectionView(
        model: WelcomeModel(
            repository: InMemoryConnectionProfileRepository(),
            credentialStore: InMemoryCredentialStore(),
            connectionTester: InMemoryConnectionTester()
        )
    )
}
