import SwiftUI

struct MCPSettingsReviewView: View {
    let policy: MCPPolicy
    let profiles: [ConnectionProfile]
    let groups: [ConnectionGroup]
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(copy("检查一下，再保存", "Review before saving")).font(.title2)
                Text(copy("以下是 AI 最终能访问的范围。", "These are the effective permissions AI will receive."))
                    .foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Form {
                Section(copy("全局设置", "Global settings")) {
                    LabeledContent("MCP", value: policy.enabled ? copy("已启用", "Enabled") : copy("已关闭", "Disabled"))
                    LabeledContent(copy("全局权限上限", "Global permission ceiling"), value: policy.mode.title)
                    LabeledContent(copy("授权范围", "Connection grants"), value: policy.allConnections
                        ? copy("全部连接，含以后新增", "All connections, including future ones")
                        : copy("指定分组与连接", "Selected groups and connections"))
                    if !policy.allConnections, !policy.groupIDs.isEmpty {
                        LabeledContent(copy("自动授权新增成员的分组", "Groups authorizing future members"), value:
                            policy.groupIDs.map { id in groups.first(where: { $0.id == id })?.name ?? id.uuidString }.sorted().joined(separator: ", "))
                    }
                    LabeledContent(copy("工具", "Tools"), value: copy("\(MCPToolCatalog.definitions.filter { !policy.disabledTools.contains($0.name) }.count) 项已启用", "\(MCPToolCatalog.definitions.filter { !policy.disabledTools.contains($0.name) }.count) enabled"))
                    LabeledContent(copy("查询超时（秒）", "Query timeout (seconds)"), value: policy.queryTimeoutSeconds.map(String.init)
                        ?? copy("继承全局设置", "Inherit QueryCraft settings"))
                    LabeledContent(copy("最大结果行数 / 字节", "Result rows / bytes"), value: "\(policy.maximumRows) / \(policy.maximumResultBytes)")
                    LabeledContent(copy("会话空闲秒数 / 每客户端会话数", "Idle seconds / sessions per client"), value: "\(policy.sessionIdleSeconds) / \(policy.maximumSessions)")
                    LabeledContent(copy("工具发现方式", "Tool discovery"), value: discoveryTitle)
                    LabeledContent(copy("结构缓存秒数 / 空闲连接数", "Metadata cache seconds / idle connections"), value: "\(policy.tuning.metadataCacheSeconds) / \(policy.tuning.maximumIdleConnections)")
                    LabeledContent(copy("记录调用摘要", "Record call summaries"), value: policy.tuning.recordsHistory ? copy("开启", "On") : copy("关闭", "Off"))
                }
                if !policy.disabledTools.isEmpty {
                    Section(copy("已停用的工具", "Disabled tools")) {
                        ForEach(policy.disabledTools.sorted(), id: \.self) { name in
                            Text(MCPToolCatalog.definitions.first(where: { $0.name == name })?.localizedTitle ?? name)
                        }
                    }
                }
                Section(copy("HTTP 配置", "HTTP configuration")) {
                    Text(policy.http.endpoint).font(MCPSettingsType.detail.monospaced()).textSelection(.enabled)
                    LabeledContent(copy("远程访问", "Remote access"), value: policy.http.allowsRemote ? copy("允许", "Allowed") : copy("关闭", "Off"))
                    Text("Hosts: \(policy.http.allowedHosts.joined(separator: ", "))").font(MCPSettingsType.detail)
                    Text("Origins: \(policy.http.allowedOrigins.joined(separator: ", "))").font(MCPSettingsType.detail)
                    Text(copy("访问令牌将使用当前编辑值，不在此展示。", "The current token will be saved without displaying it here."))
                        .font(MCPSettingsType.detail).foregroundStyle(.secondary)
                }
                ForEach(profiles) { profile in
                    Section {
                        LabeledContent(copy("最终权限", "Effective access"), value: MCPPermissionSummary.access(profile, policy: policy))
                        Text(MCPPermissionSummary.scope(profile, policy: policy))
                            .font(MCPSettingsType.detail).foregroundStyle(.secondary).textSelection(.enabled)
                        let rule = policy.connectionRule(profile)
                        ForEach((rule.databases ?? []).sorted(), id: \.self) { database in
                            LabeledContent(database, value: MCPPermissionSummary.objectAccess(database, profile: profile, policy: policy))
                                .font(MCPSettingsType.detail)
                        }
                        // Include remembered object rules even when the allowed scope is currently All.
                        ForEach(rule.databaseModes.keys.filter { rule.databases?.contains($0) != true }.sorted(), id: \.self) { database in
                            LabeledContent(database, value: MCPPermissionSummary.objectAccess(database, profile: profile, policy: policy))
                                .font(MCPSettingsType.detail)
                        }
                    } header: {
                        Text("\(profile.name) · \(profile.databaseType.title)\(groupName(profile))")
                    }
                }
                Section {
                    Text(copy("数据库账号权限、驱动能力及工具开关仍然生效；破坏性操作仍需显式确认。", "Database account permissions, driver capabilities and tool switches still apply. Destructive calls require explicit confirmation."))
                        .font(MCPSettingsType.detail).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).contentMargins(.top, 8, for: .scrollContent)
            Divider()
            HStack {
                Button(copy("返回调整", "Back to settings")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(copy("确认保存", "Save settings")) { save(); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(minWidth: 540, idealWidth: 660, minHeight: 460, idealHeight: 660)
    }

    private func groupName(_ profile: ConnectionProfile) -> String {
        guard let group = groups.first(where: { $0.id == profile.groupID }) else { return "" }
        return " · \(group.name)"
    }

    private var discoveryTitle: String {
        switch policy.tuning.discovery {
        case .flat: copy("直接工具", "Direct tools")
        case .lazy: copy("按需发现", "Lazy discovery")
        case .both: copy("两者同时", "Both")
        }
    }
}
