import SwiftUI

struct MCPConnectionPermissionRow: View {
    @Bindable var model: MCPSettingsModel
    let profile: ConnectionProfile
    @Environment(\.mcpCompactPermissionRows) private var compact
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    private var selection: MCPPermissionSelection { model.connectionSelection(profile) }
    private var effectiveAccess: String { MCPPermissionSummary.access(profile, policy: model.policy) }

    var body: some View {
        Group {
            if !compact {
                HStack(alignment: .top, spacing: 12) {
                    connectionInfo.frame(minWidth: MCPPermissionLayout.connectionMinimumWidth,
                                         idealWidth: MCPPermissionLayout.connectionIdealWidth, maxWidth: .infinity, alignment: .leading)
                    permissionControl
                    scopeControl
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    connectionInfo
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(copy("访问权限", "Access")).font(MCPSettingsType.detail).foregroundStyle(.secondary)
                            permissionControl
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(copy("访问范围", "Object scope")).font(MCPSettingsType.detail).foregroundStyle(.secondary)
                            scopeControl
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var connectionInfo: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(profile.name).fontWeight(.medium).lineLimit(1).help(profile.name)
            Text("\(profile.databaseType.title) · \(profile.host):\(String(profile.port))")
                .font(MCPSettingsType.detail).foregroundStyle(.secondary).lineLimit(1)
                .help("\(profile.host):\(profile.port)\n\(profile.id)")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionControl: some View {
        VStack(alignment: .trailing, spacing: 5) {
            MCPPermissionPicker(selection: selection, choices: [.inherited] + MCPPermissionSelection.accessChoices,
                accessibilityLabel: copy("\(profile.name)权限", "\(profile.name) access")) {
                    model.setConnectionSelection($0, for: profile)
                }
                .frame(height: 22)
            if selection != .denied && (selection == .inherited || effectiveAccess != selection.mode?.title) {
                Text(copy("生效：\(effectiveAccess)", "Effective: \(effectiveAccess)"))
                    .font(MCPSettingsType.detail).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(width: MCPPermissionLayout.controlWidth, alignment: .trailing)
    }

    private var scopeControl: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Button {
                model.selectedConnection = profile.id
                model.scopeEditorConnection = profile
            } label: { Text(copy("设置范围…", "Configure scope…")) }
            .buttonStyle(.bordered).controlSize(.small).fixedSize()
            .frame(height: 22)
            .accessibilityLabel(copy("\(profile.name)数据库与对象范围", "\(profile.name) database and object scope"))
            Text(MCPPermissionSummary.scope(profile, policy: model.policy))
                .font(MCPSettingsType.detail).foregroundStyle(.secondary).lineLimit(1)
                .help(MCPPermissionSummary.scope(profile, policy: model.policy))
        }.frame(width: MCPPermissionLayout.scopeWidth, alignment: .trailing)
    }
}
