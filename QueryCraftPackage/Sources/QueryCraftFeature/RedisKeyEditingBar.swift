import SwiftUI

struct RedisKeyEditingBar: View {
    let keyType: RedisKeyType
    @Bindable var editor: RedisKeyEditorState
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            if editor.supportsRowEditing {
                if keyType == .list {
                    WorkspaceInlineIconButton(
                        systemImageName: "arrow.up.to.line",
                        title: AppCopy.current.text(
                            "在头部新增",
                            "Add to Head"
                        ),
                        isEnabled: isEnabled,
                        action: { editor.addListRow(at: .head) }
                    )
                }
                WorkspaceInlineIconButton(
                    systemImageName: "plus",
                    title: addTitle,
                    isEnabled: isEnabled,
                    action: editor.addRow
                )
            }

            if !editor.supportsValueEditing {
                Text(readOnlyValueMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            RedisKeyExpirationControls(
                editor: editor,
                isEnabled: isEnabled
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
    }

    private var addTitle: String {
        switch keyType {
        case .hash:
            AppCopy.current.text("新增字段", "Add Field")
        case .list:
            AppCopy.current.text("在尾部新增", "Add to Tail")
        default:
            AppCopy.current.text("新增成员", "Add Member")
        }
    }

    private var readOnlyValueMessage: String {
        AppCopy.current.text(
            "此类型的值暂时只读，TTL 仍可修改。",
            "This value type is read-only for now. TTL can still be changed."
        )
    }
}
