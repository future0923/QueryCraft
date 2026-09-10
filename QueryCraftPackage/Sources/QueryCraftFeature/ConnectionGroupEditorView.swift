import SwiftUI

struct ConnectionGroupEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var name: String
    @State private var errorMessage = ""
    @State private var isSaving = false

    let mode: ConnectionGroupEditorMode
    let model: WelcomeModel

    init(mode: ConnectionGroupEditorMode, model: WelcomeModel) {
        self.mode = mode
        self.model = model
        switch mode {
        case .create:
            _name = State(initialValue: "")
        case .rename(let group):
            _name = State(initialValue: group.name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2)
                .bold()

            TextField(
                AppCopy.current.text("分组名称", "Group name"),
                text: $name
            )
                .focused($isNameFocused)
                .accessibilityIdentifier("connectionGroupNameField")
                .disabled(isSaving)

            if !errorMessage.isEmpty {
                Label(
                    errorMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Spacer()
                Button(
                    AppCopy.current.text("取消", "Cancel"),
                    action: dismiss.callAsFunction
                )
                    .keyboardShortcut(.cancelAction)
                Button(AppCopy.current.text("保存", "Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                    .accessibilityIdentifier("saveConnectionGroupButton")
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            isNameFocused = true
        }
    }

    private var title: String {
        switch mode {
        case .create:
            AppCopy.current.text("新建连接分组", "New Connection Group")
        case .rename:
            AppCopy.current.text("重命名连接分组", "Rename Connection Group")
        }
    }

    private func save() {
        errorMessage = ""
        isSaving = true
        Task {
            do {
                switch mode {
                case .create:
                    try await model.createGroup(named: name)
                case .rename(let group):
                    try await model.renameGroup(group, to: name)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
