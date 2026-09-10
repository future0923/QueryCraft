import SwiftUI

struct WorkspaceLegacySidebarTabPicker: View {
    @Binding var selection: WorkspaceSidebarMode

    var body: some View {
        Picker(
            AppCopy.current.text("侧边栏内容", "Sidebar Content"),
            selection: $selection
        ) {
            ForEach(WorkspaceSidebarMode.allCases) { mode in
                Text(mode.title)
                    .tag(mode)
                    .accessibilityIdentifier("sidebarTab.\(mode.rawValue)")
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
