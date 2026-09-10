import SwiftUI

struct RedisKeyHeaderActions: View {
    static let renameSystemImageName = "pencil"
    static let copySelectedSystemImageName = "doc.on.doc"
    static let copyWholeKeySystemImageName = "terminal"
    static let deleteSystemImageName = "trash"

    let canRename: Bool
    let canCopySelectedRows: Bool
    let canCopyWholeKey: Bool
    let canDelete: Bool
    let rename: @MainActor @Sendable () -> Void
    let copySelectedRows: @MainActor @Sendable () -> Void
    let copyWholeKey: @MainActor @Sendable () -> Void
    let delete: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: 4) {
            WorkspaceInlineIconButton(
                systemImageName: Self.renameSystemImageName,
                title: AppCopy.current.text("重命名 Key", "Rename Key"),
                isEnabled: canRename,
                action: rename
            )
            WorkspaceInlineIconButton(
                systemImageName: Self.copySelectedSystemImageName,
                title: AppCopy.current.text(
                    "复制选中行为命令",
                    "Copy Selected Rows as Command"
                ),
                isEnabled: canCopySelectedRows,
                action: copySelectedRows
            )
            WorkspaceInlineIconButton(
                systemImageName: Self.copyWholeKeySystemImageName,
                title: AppCopy.current.text(
                    "复制整个 Key 为命令",
                    "Copy Entire Key as Command"
                ),
                isEnabled: canCopyWholeKey,
                action: copyWholeKey
            )
            WorkspaceInlineIconButton(
                systemImageName: Self.deleteSystemImageName,
                title: AppCopy.current.text("删除 Key", "Delete Key"),
                isEnabled: canDelete,
                action: delete
            )
        }
        .fixedSize()
        .accessibilityIdentifier("redisKeyHeaderActions")
    }
}
