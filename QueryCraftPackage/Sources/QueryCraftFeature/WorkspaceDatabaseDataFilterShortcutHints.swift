import SwiftUI

struct WorkspaceDatabaseDataFilterShortcutHints: View {
    let showsToggleCondition: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(AppCopy.current.text("插入：⌘I", "Insert: ⌘I"))
                Text(AppCopy.current.text("移除：⇧⌘I", "Remove: ⇧⌘I"))
                Text(AppCopy.current.text("全部应用：⌘↩", "Apply All: ⌘↩"))
                Text(AppCopy.current.text("上：⌘↑", "Up: ⌘↑"))
                Text(AppCopy.current.text("下：⌘↓", "Down: ⌘↓"))
                Text(AppCopy.current.text("列：⌘←", "Columns: ⌘←"))
                Text(AppCopy.current.text("运算符：⌘→", "Operators: ⌘→"))
                if showsToggleCondition {
                    Text(AppCopy.current.text("开/关：⌘B", "On/Off: ⌘B"))
                }
                Text(AppCopy.current.text("退出：Esc", "Exit: Esc"))
            }

            HStack(spacing: 12) {
                Text(AppCopy.current.text("插入：⌘I", "Insert: ⌘I"))
                Text(AppCopy.current.text("移除：⇧⌘I", "Remove: ⇧⌘I"))
                Text(AppCopy.current.text("全部应用：⌘↩", "Apply All: ⌘↩"))
                if showsToggleCondition {
                    Text(AppCopy.current.text("开/关：⌘B", "On/Off: ⌘B"))
                }
                Text(AppCopy.current.text("退出：Esc", "Exit: Esc"))
            }

            Text(AppCopy.current.text("退出：Esc", "Exit: Esc"))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}
