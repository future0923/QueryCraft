import AppKit
import SwiftUI

struct WorkspaceDatabaseInspectorFieldRow: View {
    let field: WorkspaceDatabaseInspectorField
    let isBusy: Bool
    let applyMutation: @MainActor (
        WorkspaceDatabaseInspectorMutation
    ) -> Void

    @State private var editText: String
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    init(
        field: WorkspaceDatabaseInspectorField,
        isBusy: Bool,
        applyMutation: @escaping @MainActor (
            WorkspaceDatabaseInspectorMutation
        ) -> Void
    ) {
        self.field = field
        self.isBusy = isBusy
        self.applyMutation = applyMutation
        _editText = State(initialValue: field.editableText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if showsModificationIndicator {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }

                if field.isPrimaryKey {
                    Image(systemName: "key.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }

                Text(field.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .help(field.name)

                Spacer(minLength: 8)

                if !field.databaseTypeLabel.isEmpty {
                    Text(field.databaseTypeLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help(field.type)
                }
            }
            .textSelection(.enabled)

            TextField(
                "",
                text: editTextBinding,
                prompt: Text(prompt)
            )
            .textFieldStyle(.roundedBorder)
            .font(.subheadline)
            .focused($isFocused)
            .disabled(
                !field.isEditable || isBusy || field.isTextPreviewTruncated
            )
            .overlay(alignment: .trailing) {
                if field.isEditable && isHovered {
                    fieldMenu
                        .padding(.trailing, 4)
                }
            }
        }
        .labelsHidden()
        .onHover { isHovered = $0 }
        .help(interactionHelp)
        .accessibilityHint(interactionHelp)
        .contextMenu { fieldMenuItems }
        .onChange(of: field.value) { _, _ in
            guard !isFocused else { return }
            editText = field.editableText
        }
        .onChange(of: field.isModified) { wasModified, isModified in
            if wasModified && !isModified {
                editText = field.editableText
            }
        }
    }

    private var interactionHelp: String {
        if isBusy {
            return AppCopy.current.text(
                "正在提交更改，请稍候。",
                "Changes are being committed. Please wait."
            )
        }
        if field.isTextPreviewTruncated {
            return AppCopy.current.text(
                "值过大，当前显示预览；复制和导出仍使用完整值。",
                "This value is too large for inline editing. Copy and export still use the full value."
            )
        }
        if let editDisabledReason = field.editDisabledReason {
            return editDisabledReason
        }
        return AppCopy.current.text(
            "编辑字段“\(field.name)”",
            "Edit field \"\(field.name)\""
        )
    }

    private var fieldMenu: some View {
        Menu {
            fieldMenuItems
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isBusy)
        .help(AppCopy.current.text("字段操作", "Field Actions"))
        .accessibilityLabel(
            AppCopy.current.text("字段操作", "Field Actions")
        )
    }

    @ViewBuilder
    private var fieldMenuItems: some View {
        if field.isNullable {
            Button(
                AppCopy.current.text("设为 NULL", "Set to NULL")
            ) {
                applyMenuMutation(.null)
            }
            .disabled(!field.isEditable)
        }

        if field.canUseDefault {
            Button(
                AppCopy.current.text("使用默认值", "Use Default")
            ) {
                applyMenuMutation(.useDefault)
            }
            .disabled(!field.isEditable)
        }

        Button(
            AppCopy.current.text("设为空字符串", "Set to Empty String")
        ) {
            applyMenuMutation(.value(""))
        }
        .disabled(!field.isEditable)

        Divider()

        Button(AppCopy.current.text("复制值", "Copy Value")) {
            copyValue()
        }
    }

    private var prompt: String {
        if field.hasMultipleValues {
            return AppCopy.current.text("多个值", "Multiple values")
        }
        if editText.isEmpty,
           showsModificationIndicator,
           case .text = field.value
        {
            return field.originalValue.placeholderText
        }
        return field.value.placeholderText
    }

    private var showsModificationIndicator: Bool {
        field.isModified
            || (!field.isTextPreviewTruncated && editText != field.editableText)
    }

    private var editTextBinding: Binding<String> {
        Binding(
            get: { editText },
            set: { value in
                editText = value
                guard field.isEditable,
                    !field.isTextPreviewTruncated,
                    !isBusy
                else {
                    return
                }
                applyMutation(.value(value))
            }
        )
    }

    private func applyMenuMutation(
        _ mutation: WorkspaceDatabaseInspectorMutation
    ) {
        editText = mutation.textValue ?? ""
        applyMutation(mutation)
    }

    private func copyValue() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(field.copyText, forType: .string)
    }
}

private extension WorkspaceDatabaseInspectorField {
    var copyText: String {
        switch value {
        case .required:
            "REQUIRED"
        case .useDefault:
            "DEFAULT"
        case .null:
            "NULL"
        case let .text(value):
            value
        case let .binary(byteCount):
            "<BINARY \(byteCount) bytes>"
        }
    }
}

private extension WorkspaceDatabaseInspectorField.Value {
    var placeholderText: String {
        switch self {
        case .required:
            "REQUIRED"
        case .useDefault:
            "DEFAULT"
        case .null:
            "NULL"
        case let .text(value):
            value.isEmpty ? "EMPTY" : value
        case let .binary(byteCount):
            AppCopy.current.text(
                "二进制数据（\(byteCount) 字节）",
                "Binary data (\(byteCount) bytes)"
            )
        }
    }
}

private extension WorkspaceDatabaseInspectorMutation {
    var textValue: String? {
        guard case let .value(value) = self else { return nil }
        return value
    }
}
