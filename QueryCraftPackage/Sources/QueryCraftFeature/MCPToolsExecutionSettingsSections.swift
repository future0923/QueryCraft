import SwiftUI

/// Keep the native Form's leading labels and trailing controls. Isolating this
/// page and its groups limits the view hierarchy invalidated on category changes.
struct MCPToolsExecutionSettingsSections: View {
    @Bindable var model: MCPSettingsModel
    private let strings = AppCopy.current
    private func copy(_ zh: String, _ en: String) -> String { strings.text(zh, en) }

    var body: some View {
        Section {
            Picker(copy("执行权限", "Execution access"), selection: $model.policy.mode) {
                ForEach(MCPExecutionMode.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }.pickerStyle(.radioGroup)
            Text(modeDescription).font(MCPSettingsType.detail).foregroundStyle(.secondary)
            TextField(copy("查询超时（秒）", "Query timeout (seconds)"), text: Binding(get: {
                model.policy.queryTimeoutSeconds.map(String.init) ?? ""
            }, set: { value in
                if value.trimmingCharacters(in: .whitespaces).isEmpty { model.policy.queryTimeoutSeconds = nil }
                else if let seconds = Int(value), (0...86400).contains(seconds) { model.policy.queryTimeoutSeconds = seconds }
            }))
        } header: { Text(copy("全局执行权限", "Global execution access")) }
        footer: {
            Text(copy("超时留空继承 QueryCraft 查询设置，0 表示不限时。驱动能力与连接范围仍然生效。", "Blank timeout inherits QueryCraft settings; 0 means unlimited. Driver capabilities and connection scopes still apply."))
        }
        Section(copy("可用工具", "Available tools")) {
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
        ForEach(MCPPermissionToolGroup.allCases) { group in
            MCPPermissionToolSection(group: group, disabledTools: $model.policy.disabledTools)
        }
        Section(copy("权限能力说明", "About permissions")) {
            Text(copy("只读允许查询、结构及消息读取；数据读写允许插入及带可验证条件的更新、删除；完整访问增加 DDL 等高风险操作，破坏性操作仍需确认。事务内 DDL 与会话控制 SQL 均不开放。", "Read only permits queries, metadata and messages. Data read/write adds inserts and verifiably filtered updates/deletes. Full access adds DDL and other high-risk operations; destructive actions require confirmation. Transactional DDL and session-control SQL remain unavailable."))
                .font(MCPSettingsType.detail).foregroundStyle(.secondary)
        }
    }

    private var enabledCount: Int { MCPToolCatalog.definitions.filter { !model.policy.disabledTools.contains($0.name) }.count }
    private var modeDescription: String {
        switch model.policy.mode {
        case .readOnly: copy("允许查询、查看结构和读取消息。", "Query data, inspect structure and read messages.")
        case .dataWrite: copy("允许插入及带可验证条件的更新、删除。", "Insert, update and delete using verifiable filters.")
        case .fullAccess: copy("允许驱动支持的高风险操作；破坏性操作仍需明确确认。", "Allow supported high-risk operations; destructive actions still require confirmation.")
        }
    }
}

private struct MCPPermissionToolSection: View {
    let group: MCPPermissionToolGroup
    @Binding var disabledTools: Set<String>

    var body: some View {
        Section(group.title) {
            ForEach(group.tools, id: \.name) { tool in
                Toggle(tool.localizedTitle, isOn: Binding(get: { !disabledTools.contains(tool.name) }, set: { enabled in
                    if enabled { disabledTools.remove(tool.name) } else { disabledTools.insert(tool.name) }
                }))
                .toggleStyle(.checkbox).help("querycraft_\(tool.name)\n\(tool.description)")
            }
        }
    }
}
