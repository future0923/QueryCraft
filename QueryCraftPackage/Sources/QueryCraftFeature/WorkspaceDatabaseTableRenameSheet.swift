import SwiftUI

struct WorkspaceDatabaseTableRenameSheet: View {
    let selection: WorkspaceDatabaseObjectSelection
    let model: WorkspaceModel
    let didRename: @MainActor (
        WorkspaceDatabaseObjectSelection,
        WorkspaceDatabaseObjectSelection
    ) -> Void
    let dismiss: @MainActor () -> Void

    @State private var tableName: String
    @State private var showsSQLPreview = false
    @State private var showsSafetyLockConfirmation = false
    @State private var errorMessage: String?
    @State private var submissionTask: Task<Void, Never>?
    @State private var pendingExecutionPlan: WorkspaceDatabaseSchemaExecutionPlan?

    init(
        selection: WorkspaceDatabaseObjectSelection,
        model: WorkspaceModel,
        didRename: @escaping @MainActor (
            WorkspaceDatabaseObjectSelection,
            WorkspaceDatabaseObjectSelection
        ) -> Void,
        dismiss: @escaping @MainActor () -> Void
    ) {
        self.selection = selection
        self.model = model
        self.didRename = didRename
        self.dismiss = dismiss
        let initialName: String
        if model.databaseType == .postgresql,
           let separator = selection.objectName.firstIndex(of: ".") {
            initialName = String(selection.objectName[selection.objectName.index(
                after: separator
            )...])
        } else {
            initialName = selection.objectName
        }
        _tableName = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppCopy.current.text("重命名表", "Rename Table"))
                .font(.title2)
                .fontWeight(.semibold)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(AppCopy.current.text("表名", "Table Name"))
                TextField("", text: $tableName)
                    .accessibilityIdentifier("renameTableNameField")
            }

            HStack(spacing: 10) {
                Button(
                    AppCopy.current.text("预览 SQL", "Preview SQL"),
                    systemImage: "eye"
                ) {
                    showsSQLPreview = true
                }
                .disabled(isSubmitting)
                .popover(isPresented: $showsSQLPreview, arrowEdge: .bottom) {
                    WorkspaceSQLPreviewView(
                        statements: executionPlan.map {
                            WorkspaceSQLPreviewStatement.make(
                                schemaExecutionPlan: $0
                            )
                        } ?? [],
                        dismiss: { showsSQLPreview = false }
                    )
                }

                Spacer()

                Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)

                Button(
                    isSubmitting
                        ? AppCopy.current.text("正在重命名…", "Renaming...")
                        : AppCopy.current.text("重命名", "Rename"),
                    action: requestSubmit
                )
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
                .accessibilityIdentifier("renameTableButton")
            }
        }
        .padding(20)
        .frame(width: 460)
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $showsSafetyLockConfirmation
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive
            ) {
                model.safetyLock.disable()
                submit()
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(
                AppCopy.current.text(
                    "重命名表会更改数据库结构。安全锁将保持停用，直到此工作区关闭。",
                    "Renaming a table changes the database structure. Safety Lock will remain disabled until this workspace closes."
                )
            )
        }
        .alert(
            AppCopy.current.text("无法重命名表", "Unable to Rename Table"),
            isPresented: errorPresentation
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            submissionTask?.cancel()
        }
    }

    private var mutation: WorkspaceDatabaseTableMutation {
        .rename(selection: selection, newName: tableName)
    }

    private var isSubmitting: Bool { submissionTask != nil }

    private var executionPlan: WorkspaceDatabaseSchemaExecutionPlan? {
        try? model.schemaExecutionPlan(for: mutation)
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private func requestSubmit() {
        guard let executionPlan else {
            errorMessage = AppCopy.current.text(
                "无法生成重命名 SQL。",
                "Unable to generate rename SQL."
            )
            return
        }
        pendingExecutionPlan = executionPlan
        if model.safetyLock.isEnabled {
            showsSafetyLockConfirmation = true
        } else {
            submit()
        }
    }

    private func submit() {
        guard
            submissionTask == nil,
            let executionPlan = pendingExecutionPlan,
            case let .tableMutation(submittedMutation) = executionPlan.source
        else { return }
        submissionTask = Task { @MainActor in
            defer {
                submissionTask = nil
                pendingExecutionPlan = nil
            }
            do {
                try await model.applyTableMutation(executionPlan)
                try Task.checkCancellation()
                guard var newSelection = submittedMutation.resultingSelection else {
                    return
                }
                if model.databaseType == .postgresql,
                   let separator = selection.objectName.firstIndex(of: ".") {
                    let schema = selection.objectName[..<separator]
                    newSelection = WorkspaceDatabaseObjectSelection(
                        databaseName: selection.databaseName,
                        objectName: "\(schema).\(newSelection.objectName)",
                        kind: .table
                    )
                }
                didRename(selection, newSelection)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
