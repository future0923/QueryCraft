import SwiftUI

public struct WorkspaceContentTabCommands: Commands {
    @FocusedValue(\.workspaceContentTabActions) private var actions

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(
                actions?.createDocumentTitle
                    ?? AppCopy.current.text("新建查询标签页", "New Query Tab"),
                systemImage: "plus"
            ) {
                actions?.createQuery()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(actions?.canCreateQuery != true)

            Divider()

            Button(AppCopy.current.text("关闭标签页", "Close Tab")) {
                actions?.closeSelected()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(actions == nil)

            ForEach(1...9, id: \.self) { number in
                Button(
                    AppCopy.current.text(
                        "选择标签页 \(number)",
                        "Select Tab \(number)"
                    )
                ) {
                    actions?.selectAtIndex(number - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(number))))
                .disabled(actions?.hasContentTabs != true)
            }

            Button(AppCopy.current.text("下一个标签页", "Next Tab")) {
                actions?.selectRelative(1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(actions?.hasContentTabs != true)

            Button(AppCopy.current.text("上一个标签页", "Previous Tab")) {
                actions?.selectRelative(-1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(actions?.hasContentTabs != true)
        }
    }

    public init() {}
}
