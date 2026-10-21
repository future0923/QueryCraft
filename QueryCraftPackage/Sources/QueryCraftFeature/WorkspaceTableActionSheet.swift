import SwiftUI

struct WorkspaceTableActionSheet: View {
    let request: WorkspaceTableActionRequest
    let model: WorkspaceModel
    let hasPendingChanges: @MainActor () -> Bool
    let didComplete: @MainActor (WorkspaceTableActionStatement) -> Void
    let dismiss: @MainActor () -> Void
    @State private var input: String
    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var showsSQL = false
    @State private var showsUnlock = false
    @State private var isSubmitting = false
    @State private var hasCompleted = false
    @State private var submissionTask: Task<Void, Never>?

    init(request: WorkspaceTableActionRequest, model: WorkspaceModel,
         hasPendingChanges: @escaping @MainActor () -> Bool,
         didComplete: @escaping @MainActor (WorkspaceTableActionStatement) -> Void,
         dismiss: @escaping @MainActor () -> Void) {
        self.request = request
        self.model = model
        self.hasPendingChanges = hasPendingChanges
        self.didComplete = didComplete
        self.dismiss = dismiss
        _input = State(initialValue: request.action == .rename
                       ? (model.databaseType == .postgresql ? request.selection.object.nameWithinSchema : request.selection.objectName) : "1")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.action.title).font(.title2).fontWeight(.semibold)
            Text("\(request.selection.databaseName) / \(request.selection.objectName)")
                .font(.headline).textSelection(.enabled)
            Text(request.action.explanation(for: model.databaseType))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if request.action == .rename || request.action == .setAutoIncrement {
                LabeledContent(AppCopy.current.text(request.action == .rename ? "新表名" : "下一自增值",
                                                   request.action == .rename ? "New name" : "Next value")) {
                    TextField("", text: $input)
                        .accessibilityIdentifier("tableActionInput")
                }
            }
            if request.action.isDestructive {
                Text(AppCopy.current.text("输入表名以确认：", "Enter the table name to confirm:"))
                TextField(request.selection.objectName, text: $confirmation)
                    .accessibilityIdentifier("tableActionConfirmation")
            }
            Text(errorMessage ?? " ")
                .foregroundStyle(.red).font(.callout)
                .lineLimit(2).help(errorMessage ?? "")
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 40, alignment: .topLeading)
                .accessibilityIdentifier("tableActionError")
            HStack {
                Button(AppCopy.current.text("预览 SQL", "Preview SQL"), systemImage: "eye") { showsSQL = true }
                    .disabled(statement == nil || isSubmitting)
                    .popover(isPresented: $showsSQL) {
                        WorkspaceSQLPreviewView(statements: statement.map {
                            [.init(tokens: [.init(text: $0.sql + ";", kind: .expression)])]
                        } ?? [], dismiss: { showsSQL = false })
                    }
                Spacer()
                Button(hasCompleted ? AppCopy.current.text("关闭", "Close") : AppCopy.current.text("取消", "Cancel"), role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction).disabled(isSubmitting)
                Button(request.action.title, role: request.action.isDestructive ? .destructive : nil, action: submit)
                    .disabled(isSubmitting || hasCompleted || !isConfirmed || statement == nil)
                    .accessibilityIdentifier("tableActionSubmit")
            }
            WorkspaceDatabaseDataProgressBar(isActive: isSubmitting).frame(height: 3)
        }
        .padding(20).frame(width: 540)
        .disabled(isSubmitting)
        .interactiveDismissDisabled(isSubmitting)
        .alert(AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"), isPresented: $showsUnlock) {
            Button(AppCopy.current.text("允许此工作区进行更改", "Allow Changes for This Workspace"), role: .destructive) {
                model.safetyLock.disable()
                submit()
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(AppCopy.current.text("安全锁将保持停用，直到此工作区关闭。", "Safety Lock will remain disabled until this workspace closes."))
        }
        .onChange(of: input) { _, _ in
            do { _ = try makeStatement(); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        }
        .onDisappear { submissionTask?.cancel() }
    }

    private var isConfirmed: Bool {
        !request.action.isDestructive || confirmation == request.selection.objectName
    }

    private var statement: WorkspaceTableActionStatement? { try? makeStatement() }

    private func makeStatement() throws -> WorkspaceTableActionStatement {
        try .make(action: request.action, selection: request.selection, databaseType: model.databaseType, input: input)
    }

    private func submit() {
        guard !isSubmitting, !hasCompleted, isConfirmed else { return }
        guard model.isCurrentTableAction(request) else {
            errorMessage = WorkspaceDatabaseTableMutationError.contextChanged.localizedDescription
            return
        }
        guard !hasPendingChanges() else {
            errorMessage = WorkspaceTableActionError.pendingChanges.localizedDescription
            return
        }
        guard !model.safetyLock.isEnabled else { showsUnlock = true; return }
        do {
            let statement = try makeStatement()
            isSubmitting = true
            errorMessage = nil
            submissionTask = Task { @MainActor in
                defer { isSubmitting = false; submissionTask = nil }
                do {
                    let refreshWarning = try await model.performTableAction(request, statement: statement)
                    guard model.isCurrentTableAction(request) else { return }
                    didComplete(statement)
                    hasCompleted = true
                    if let refreshWarning { errorMessage = refreshWarning } else { dismiss() }
                } catch is CancellationError {
                    return
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
