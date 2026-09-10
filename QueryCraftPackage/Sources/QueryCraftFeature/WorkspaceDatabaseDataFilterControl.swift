import SwiftUI

struct WorkspaceDatabaseDataFilterControl: View {
    let isPresented: Bool
    let hasActiveFilter: Bool
    let isDisabled: Bool
    let toggle: () -> Void

    var body: some View {
        Group {
            if isPresented || hasActiveFilter {
                Button(
                    AppCopy.current.text("筛选", "Filter"),
                    systemImage: "line.3.horizontal.decrease",
                    action: toggle
                )
                .buttonStyle(.borderedProminent)
            } else {
                Button(
                    AppCopy.current.text("筛选", "Filter"),
                    systemImage: "line.3.horizontal.decrease",
                    action: toggle
                )
                .buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.roundedRectangle)
        .controlSize(.regular)
        .frame(height: WorkspaceDataActionControlMetrics.height)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isDisabled)
        .help(
            AppCopy.current.text(
                "筛选表数据（⇧⌘F）",
                "Filter Table Data (⇧⌘F)"
            )
        )
        .accessibilityIdentifier("databaseDataFilterButton")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if isPresented {
            return AppCopy.current.text("已打开", "On")
        }
        if hasActiveFilter {
            return AppCopy.current.text("已应用", "Applied")
        }
        return AppCopy.current.text("已关闭", "Off")
    }
}
