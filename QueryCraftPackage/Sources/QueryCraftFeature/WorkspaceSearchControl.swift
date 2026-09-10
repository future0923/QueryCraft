import SwiftUI

struct WorkspaceSearchControl: View {
    let isPresented: Bool
    let isEnabled: Bool
    let togglePresentation: @MainActor @Sendable () -> Void

    var body: some View {
        Group {
            if isPresented {
                Button(
                    AppCopy.current.text("查找", "Find"),
                    systemImage: "magnifyingglass",
                    action: togglePresentation
                )
                .buttonStyle(.borderedProminent)
            } else {
                Button(
                    AppCopy.current.text("查找", "Find"),
                    systemImage: "magnifyingglass",
                    action: togglePresentation
                )
                .buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.roundedRectangle)
        .controlSize(.regular)
        .frame(height: WorkspaceDataActionControlMetrics.height)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!isEnabled)
        .help(
            AppCopy.current.text(
                "在结果中查找（⌘F）",
                "Find in Results (⌘F)"
            )
        )
        .accessibilityIdentifier("searchGridButton")
        .accessibilityValue(
            isPresented
                ? AppCopy.current.text("已打开", "On")
                : AppCopy.current.text("已关闭", "Off")
        )
    }
}
