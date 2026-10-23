import SwiftUI

struct MCPPermissionsSettingsPane: View {
    @Bindable var model: MCPSettingsModel

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                Form { pageSections }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, 8, for: .scrollContent)
                    .id(model.authorizationStep)
                    .task(id: model.settingsNavigationRevision) {
                        if model.section == "permissions", let target = model.settingsScrollTarget {
                            await Task.yield()
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
            }
            .environment(\.mcpCompactPermissionRows, geometry.size.width < 650)
            .font(MCPSettingsType.body).controlSize(.regular)
        }
    }

    @ViewBuilder private var pageSections: some View {
        switch model.authorizationStep {
        case "tools": MCPToolsExecutionSettingsSections(model: model)
        case "execution": MCPExecutionSettingsSections(model: model)
        case "tuning": MCPOptimizationSettingsSections(model: model)
        case "ceiling", "overrides": MCPPermissionCeilingSection(model: model)
        default:
            MCPSSHAccessSection(directory: model.directory)
            MCPPermissionsSettingsSections(model: model)
        }
    }
}
