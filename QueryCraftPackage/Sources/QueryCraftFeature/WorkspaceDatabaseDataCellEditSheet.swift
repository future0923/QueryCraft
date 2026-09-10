import SwiftUI

struct WorkspaceDatabaseDataCellEditSheet: View {
    let request: WorkspaceDatabaseDataCellEditRequest
    let submit: @MainActor (WorkspaceDatabaseDataCellUpdate) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var usesNull: Bool
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var submitTask: Task<Void, Never>?
    @FocusState private var isEditorFocused: Bool

    init(
        request: WorkspaceDatabaseDataCellEditRequest,
        submit: @escaping @MainActor (
            WorkspaceDatabaseDataCellUpdate
        ) async throws -> Void
    ) {
        self.request = request
        self.submit = submit
        _text = State(initialValue: request.initialText)
        _usesNull = State(initialValue: request.initiallyUsesNull)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                AppCopy.current.text("编辑单元格", "Edit Cell"),
                systemImage: "pencil"
            )
            .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                metadataRow(
                    label: AppCopy.current.text("表", "Table"),
                    value: request.selection.objectName
                )
                metadataRow(
                    label: AppCopy.current.text("列", "Column"),
                    value: request.column.name
                )
                metadataRow(
                    label: AppCopy.current.text("类型", "Type"),
                    value: request.column.type
                )
            }

            Divider()

            Toggle(
                AppCopy.current.text("将值设为 NULL", "Set value to NULL"),
                isOn: $usesNull
            )
            .disabled(!request.column.isNullable || isSubmitting)

            TextEditor(text: $text)
                .font(.body.monospaced())
                .focused($isEditorFocused)
                .disabled(usesNull || isSubmitting)
                .frame(minHeight: 150)
                .padding(5)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }

            Text(
                AppCopy.current.text(
                    "保存后立即提交到 MySQL，并刷新当前数据页。",
                    "Saving commits immediately to MySQL and refreshes the current data page."
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Divider()

            HStack {
                Spacer()
                Button(AppCopy.current.text("取消", "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)

                Button(
                    isSubmitting
                        ? AppCopy.current.text("正在保存…", "Saving...")
                        : AppCopy.current.text("保存", "Save"),
                    systemImage: isSubmitting ? "hourglass" : "checkmark",
                    action: beginSubmit
                )
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges || isSubmitting)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 390)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            isEditorFocused = !usesNull
        }
        .onChange(of: usesNull) { _, usesNull in
            if !usesNull {
                isEditorFocused = true
            }
        }
        .onDisappear {
            submitTask?.cancel()
            submitTask = nil
        }
    }

    private var hasChanges: Bool {
        let value = usesNull
            ? WorkspaceDatabaseDataCell.null
            : WorkspaceDatabaseDataCell.text(text)
        return value != request.originalValue
            && (!usesNull || request.column.isNullable)
    }

    private func metadataRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func beginSubmit() {
        guard !isSubmitting else { return }
        do {
            let update = try request.makeUpdate(text: text, usesNull: usesNull)
            errorMessage = nil
            isSubmitting = true
            submitTask = Task { @MainActor in
                do {
                    try await submit(update)
                    guard !Task.isCancelled else { return }
                    dismiss()
                } catch is CancellationError {
                    isSubmitting = false
                } catch {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
                submitTask = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
