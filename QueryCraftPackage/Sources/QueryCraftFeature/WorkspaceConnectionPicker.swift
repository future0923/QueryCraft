import SwiftUI

struct WorkspaceConnectionPicker: View {
    @State private var model: WorkspaceConnectionPickerModel
    @State private var reloadRequestID: UUID?

    private let selectConnection: @MainActor (ConnectionProfile) -> Void
    private let dismiss: @MainActor () -> Void

    init(
        model: WorkspaceConnectionPickerModel,
        selectConnection: @escaping @MainActor (ConnectionProfile) -> Void,
        dismiss: @escaping @MainActor () -> Void
    ) {
        _model = State(initialValue: model)
        self.selectConnection = selectConnection
        self.dismiss = dismiss
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 12) {
            Text(AppCopy.current.text("切换连接", "Switch Connection"))
                .font(.headline)

            WorkspaceGridSearchField(
                text: $model.searchText,
                placeholder: AppCopy.current.text(
                    "搜索连接",
                    "Search connections"
                ),
                focusRequest: 1,
                submit: openSelection,
                cancel: dismiss,
                moveUp: { model.moveSelection(by: -1) },
                moveDown: { model.moveSelection(by: 1) }
            )
            .frame(height: 24)

            connectionList

            HStack {
                Button(
                    AppCopy.current.text("取消", "Cancel"),
                    action: dismiss
                )
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(
                    AppCopy.current.text("打开", "Open"),
                    action: openSelection
                )
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedProfile == nil || model.isLoading)
            }
        }
        .padding(16)
        .frame(width: 420, height: 460)
        .task(id: reloadRequestID) {
            guard reloadRequestID != nil else { return }
            await model.load()
        }
    }

    @ViewBuilder
    private var connectionList: some View {
        if model.isLoading {
            ProgressView(
                AppCopy.current.text(
                    "正在加载连接…",
                    "Loading connections..."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = model.errorMessage {
            ContentUnavailableView {
                Label(
                    AppCopy.current.text(
                        "无法加载连接",
                        "Unable to Load Connections"
                    ),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(errorMessage)
            } actions: {
                Button(AppCopy.current.text("重试", "Retry")) {
                    reloadRequestID = UUID()
                }
            }
        } else if model.filteredProfiles.isEmpty {
            if model.searchText.isEmpty {
                ContentUnavailableView(
                    AppCopy.current.text("暂无连接", "No Connections"),
                    systemImage: "network",
                    description: Text(
                        AppCopy.current.text(
                            "请先在欢迎窗口中创建连接。",
                            "Create a connection in the Welcome Window first."
                        )
                    )
                )
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        } else {
            ScrollViewReader { proxy in
                List(model.filteredProfiles, selection: $model.selectionID) {
                    profile in
                    WorkspaceConnectionPickerRow(
                        profile: profile,
                        endpoint: model.endpoint(for: profile),
                        isSelected: model.selectionID == profile.id
                    )
                    .tag(profile.id)
                    .id(profile.id)
                    .listRowSeparator(.hidden)
                    .onTapGesture(count: 2) {
                        open(profile)
                    }
                    .accessibilityIdentifier(
                        "connectionPicker.\(profile.id.uuidString)"
                    )
                }
                .listStyle(.inset)
                .onChange(of: model.selectionID) { _, selectionID in
                    guard let selectionID else { return }
                    proxy.scrollTo(selectionID, anchor: .center)
                }
            }
        }
    }

    private func openSelection() {
        guard let profile = model.selectedProfile else { return }
        open(profile)
    }

    private func open(_ profile: ConnectionProfile) {
        selectConnection(profile)
        dismiss()
    }
}
