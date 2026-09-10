import SwiftUI

struct WorkspaceSidebarTabBar: View {
    @Binding var selection: WorkspaceSidebarMode

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                HStack(spacing: 0) {
                    ForEach(WorkspaceSidebarMode.allCases) { mode in
                        Button {
                            selection = mode
                        } label: {
                            Text(mode.title)
                                .lineLimit(1)
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: .infinity
                                )
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .frame(height: 30)
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .background(
                            mode == selection
                                ? Color(
                                    nsColor:
                                        WorkspaceSelectionAppearance
                                        .backgroundColor
                                )
                                : Color.clear,
                            in: .rect(cornerRadius: 6)
                        )
                        .padding(.horizontal, 2)
                        .accessibilityAddTraits(
                            mode == selection ? .isSelected : []
                        )
                        .accessibilityIdentifier(
                            "sidebarTab.\(mode.rawValue)"
                        )
                    }
                }
                .frame(height: 32)
            } else {
                WorkspaceLegacySidebarTabPicker(selection: $selection)
            }
        }
        .accessibilityLabel(
            AppCopy.current.text("侧边栏内容", "Sidebar Content")
        )
    }
}
