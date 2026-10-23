import SwiftUI

struct MCPPermissionsSettingsSections: View {
    @Bindable var model: MCPSettingsModel
    @State private var confirmsRevocation = false
    @FocusState private var searchFocused: Bool
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }

    var body: some View {
        Section {
            Picker(copy("允许访问", "Allow access to"), selection: $model.policy.allConnections) {
                Text(copy("指定分组与连接", "Selected groups and connections")).tag(false)
                Text(copy("全部连接（含以后新增）", "All connections, including future ones")).tag(true)
            }.pickerStyle(.menu)
            Text(model.policy.allConnections
                 ? copy("当前及以后新增的连接都会授权，操作权限仍按下方设置。", "Current and future connections are authorized, with operation limits configured below.")
                 : copy("在下方给需要的分组或连接选择权限；其余连接不允许访问。", "Choose access for the groups or connections below; all others remain inaccessible."))
                .font(MCPSettingsType.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: { Text(copy("数据库连接范围", "Database connection scope")) }
        .id("permission-scope")
        Section {
            if !model.policy.enabled {
                HStack {
                    Text(copy("MCP 已关闭，所有连接当前均不可访问。", "MCP is disabled. All connections are currently inaccessible."))
                    Spacer(minLength: 8)
                    Button(copy("去开启", "Enable MCP")) { model.section = "access" }
                }
            }
            if model.connectionFilterVisible || !model.search.isEmpty {
                HStack(spacing: 10) {
                    TextField(copy("筛选连接、分组或地址", "Filter connections, groups or hosts"), text: $model.search,
                              prompt: Text(copy("筛选连接、分组或地址", "Filter connections, groups or hosts")))
                        .textFieldStyle(.roundedBorder).labelsHidden().focused($searchFocused)
                        .help(copy("也支持驱动、数据库名称和连接 ID", "Also searches drivers, database names and connection IDs"))
                    Button(copy("清除", "Clear")) {
                        model.search = ""; model.connectionFilterVisible = false
                    }.fixedSize()
                }
            }
            Text(copy("只读：查看数据 · 数据读写：增删改数据 · 完整访问：含结构操作", "Read only: view data · Read/write: change data · Full access: includes schema operations"))
                .font(MCPSettingsType.detail).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).help(accessHelpText)
        } header: {
            HStack(spacing: 12) {
                Text(copy("数据库连接权限", "Database connection access"))
                Spacer(minLength: 8)
                Button {
                    model.connectionFilterVisible.toggle()
                    if !model.connectionFilterVisible { model.search = "" }
                } label: { Label(copy("筛选", "Filter"), systemImage: "line.3.horizontal.decrease.circle") }
                    .buttonStyle(.borderless).controlSize(.small).fixedSize()
                Menu(copy("批量操作", "Bulk actions")) {
                    Button(copy("授权未授权连接（只读）", "Authorize remaining connections (read only)")) { model.allowSearchResultsReadOnly() }
                    Button(copy("撤销全部授权…", "Revoke all grants…"), role: .destructive) { confirmsRevocation = true }
                }.controlSize(.small).fixedSize()
            }
        }
        .task(id: model.connectionFilterVisible) {
            if model.connectionFilterVisible { await Task.yield(); searchFocused = true }
        }
        .id("permission-connections")
        .confirmationDialog(copy("撤销全部 MCP 连接授权？数据库范围和权限规则将保留。", "Revoke all MCP connection grants? Object scopes and permission rules will be preserved."), isPresented: $confirmsRevocation) {
            Button(copy("撤销全部授权", "Revoke all grants"), role: .destructive) { model.revokeAllConnectionGrants() }
        }

        ForEach(model.visiblePermissionGroups) { group in
            MCPPermissionGroupSection(model: model, group: group)
        }
        if model.visiblePermissionGroups.isEmpty && model.didLoad && model.error == nil {
            Section {
                Text(copy("没有匹配的连接或分组", "No matching connections or groups")).foregroundStyle(.secondary)
            }
        }
    }

    private var accessHelpText: String {
        copy("只读：查询、查看结构和读取消息。MySQL / PostgreSQL 使用只读事务；Doris 不提供同样的事务保证。\n数据读写：允许插入，以及带可验证过滤条件的更新、删除；不允许修改结构。\n完整访问：允许驱动支持的高级操作，破坏性调用仍需显式确认。数据库账号权限和工具开关继续生效。", "Read only: queries, metadata and messages. MySQL/PostgreSQL use read-only transactions; Doris does not provide the same guarantee.\nRead/write: inserts and verifiably filtered updates/deletes, without schema changes.\nFull access: supported advanced operations. Destructive calls require confirmation; database account permissions and tool switches still apply.")
    }
}
