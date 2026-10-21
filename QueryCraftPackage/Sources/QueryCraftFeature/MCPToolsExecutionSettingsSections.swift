import SwiftUI

/// Keep the native Form's leading labels and trailing controls. Isolating this
/// page and its groups limits the view hierarchy invalidated on category changes.
struct MCPToolsExecutionSettingsSections: View {
    @Bindable var model: MCPSettingsModel
    private let strings = AppCopy.current
    private func copy(_ zh: String, _ en: String) -> String { strings.text(zh, en) }

    var body: some View {
        Section(copy("全局工具开关", "Global tool switches")) {
            HStack {
                Text(copy("已启用 \(enabledCount) 项", "\(enabledCount) enabled"))
                    .font(MCPSettingsType.detail).foregroundStyle(.secondary)
                Spacer()
                Menu(copy("选择", "Select")) {
                    Button(copy("全部启用", "Enable all")) { model.policy.disabledTools = [] }
                    Button(copy("全部停用", "Disable all")) { model.policy.disabledTools = Set(MCPToolCatalog.definitions.map(\.name)) }
                }.fixedSize()
            }
        }
        Text(copy("启用工具不会增加连接的读写权限，每次调用仍按目标连接的实际权限检查。", "Enabling a tool never increases connection access. Every call is checked against its target connection's effective permissions."))
            .font(MCPSettingsType.detail).foregroundStyle(.secondary)
        ForEach(MCPPermissionToolGroup.allCases) { group in
            MCPPermissionToolSection(group: group, disabledTools: $model.policy.disabledTools)
        }
        Section(copy("权限能力说明", "About permissions")) {
            Text(copy("只读允许查询、结构及消息读取；数据读写允许插入及带可验证条件的更新、删除；完整访问增加 DDL 等高风险操作，破坏性操作仍需确认。事务内 DDL 与会话控制 SQL 均不开放。", "Read only permits queries, metadata and messages. Data read/write adds inserts and verifiably filtered updates/deletes. Full access adds DDL and other high-risk operations; destructive actions require confirmation. Transactional DDL and session-control SQL remain unavailable."))
                .font(MCPSettingsType.detail).foregroundStyle(.secondary)
        }
    }

    private var enabledCount: Int { MCPToolCatalog.definitions.filter { !model.policy.disabledTools.contains($0.name) }.count }

}

private struct MCPPermissionToolSection: View {
    let group: MCPPermissionToolGroup
    @Binding var disabledTools: Set<String>

    var body: some View {
        Section {
            ForEach(group.tools, id: \.name) { tool in
                Toggle(tool.localizedTitle, isOn: Binding(get: { !disabledTools.contains(tool.name) }, set: { enabled in
                    if enabled { disabledTools.remove(tool.name) } else { disabledTools.insert(tool.name) }
                }))
                .toggleStyle(.checkbox).help("querycraft_\(tool.name)\n\(tool.description)")
            }
        } header: {
            HStack {
                Text(group.title)
                Spacer()
                Toggle(AppCopy.current.text("整组启用", "Enable group"), isOn: Binding(
                    get: { group.tools.allSatisfy { !disabledTools.contains($0.name) } },
                    set: { enabled in
                        let names = Set(group.tools.map(\.name))
                        if enabled { disabledTools.subtract(names) } else { disabledTools.formUnion(names) }
                    }))
                    .toggleStyle(.checkbox)
            }
        }
    }
}
