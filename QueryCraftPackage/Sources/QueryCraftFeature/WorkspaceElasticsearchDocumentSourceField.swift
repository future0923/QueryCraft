import SwiftUI

struct WorkspaceElasticsearchDocumentSourceField: View {
    let context: WorkspaceElasticsearchDocumentInspectorContext
    let source: String

    var body: some View {
        @Bindable var model = context.model

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("_source")
                    .font(.subheadline)

                Spacer(minLength: 8)

                Text("json")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())

                WorkspaceInlineIconButton(
                    systemImageName: model.isEditing ? "xmark" : "pencil",
                    title: model.isEditing
                        ? AppCopy.current.text("结束编辑", "Finish Editing")
                        : AppCopy.current.text("编辑文档", "Edit Document"),
                    isEnabled: model.isEditing || model.canBeginEditing,
                    action: model.isEditing
                        ? context.endEditing
                        : context.beginEditing
                )
            }

            if model.isEditing {
                WorkspaceCodeEditJSONEditor(text: $model.draftText)
                    .onChange(of: model.draftText) { _, text in
                        context.updateDraft(text)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 72,
                        maxHeight: .infinity
                    )

                validationStatus(model)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            } else {
                WorkspaceReadOnlyTextView(
                    text: source,
                    usesMonospacedFont: true,
                    accessibilityLabel: AppCopy.current.text(
                        "原始 JSON",
                        "Raw JSON"
                    ),
                    presentation: .json
                )
                .frame(maxWidth: .infinity, minHeight: 72, maxHeight: .infinity)
                validationStatus(model)
                    .lineLimit(1)
                    .help(model.validationErrorMessage ?? "")
                    .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func validationStatus(
        _ model: WorkspaceElasticsearchDocumentInspectorModel
    ) -> some View {
        if model.editingState == .conflicted || model.cellChanges.isBlocked {
            Label(
                AppCopy.current.text(
                    "提交已停止，请核实服务器状态或放弃草稿。",
                    "Submission stopped. Verify server state or discard the draft."
                ),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.red)
        } else if let message = model.validationErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } else if model.isValidating {
            Text(AppCopy.current.text("正在检查 JSON…", "Validating JSON..."))
                .foregroundStyle(.secondary)
        } else if model.hasChanges {
            Text(AppCopy.current.text("有待提交更改", "Changes pending"))
                .foregroundStyle(.secondary)
        } else {
            Text(" ")
                .accessibilityHidden(true)
        }
    }
}
