import SwiftUI

/// Permission controls share the host settings form, rather than embedding a second sidebar.
struct MCPPermissionsSettingsSections: View {
    @Bindable var model: MCPSettingsModel
    let step: String
    private let strings = AppCopy.current
    private func copy(_ zh: String, _ en: String) -> String { strings.text(zh, en) }
    private var selectedProfile: ConnectionProfile? {
        model.authorizedProfiles.first { $0.id == model.selectedConnection }
    }

    var body: some View {
        Section {
            Picker(copy("权限项目", "Configure"), selection: Binding(get: { model.authorizationStep }, set: { step in
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { model.authorizationStep = step }
            })) {
                Text(copy("连接", "Connections")).tag("connections")
                Text(copy("数据库与对象", "Databases and objects")).tag("databases")
                Text(copy("权限限制", "Permission limits")).tag("overrides")
                Text(copy("工具与执行", "Tools and execution")).tag("tools")
            }.pickerStyle(.menu)
        }
        // This page's content identity is independent of the shared picker.
        // Previously opened pages remain alive when another category is selected.
        switch step {
        case "connections": connectionScope
        case "databases": databaseScope
        case "overrides": permissionOverrides
        default: MCPToolsExecutionSettingsSections(model: model)
        }
    }

    @ViewBuilder private var connectionScope: some View {
        Section {
            Picker(copy("允许访问", "Allow access to"), selection: $model.policy.allConnections) {
                Text(copy("指定连接与分组", "Selected connections and groups")).tag(false)
                Text(copy("全部连接", "All connections")).tag(true)
            }.pickerStyle(.menu)
            TextField(copy("搜索连接", "Search connections"), text: $model.search, prompt: Text(copy("搜索连接", "Search connections")))
                .textFieldStyle(.roundedBorder).labelsHidden()
                .help(copy("按名称、类型、地址、数据库或 ID 搜索", "Search by name, type, host, database or ID"))
            Table(model.filteredProfiles) {
                TableColumn(copy("允许", "Allow")) { profile in
                    Toggle(profile.name, isOn: Binding(get: { model.policy.includesConnection(profile) }, set: { allowed in
                        if allowed { model.policy.connectionIDs.insert(profile.id) }
                        else { model.removeConnection(profile) }
                    }))
                    .labelsHidden().toggleStyle(.checkbox).disabled(model.policy.allConnections)
                }.width(44)
                TableColumn(copy("连接", "Connection")) { profile in connectionLabel(profile) }
                TableColumn(copy("驱动", "Driver")) { profile in Text(profile.databaseType.title).font(MCPSettingsType.detail) }.width(90)
            }
            .frame(height: 340)
            .overlay {
                if model.filteredProfiles.isEmpty && model.didLoad && !model.isBusy && model.error == nil {
                    Text(copy("没有匹配的连接", "No matching connections")).font(.callout).foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            HStack {
                Text(copy("已允许 \(model.authorizedProfiles.count) 个连接", "\(model.authorizedProfiles.count) connections allowed"))
                    .font(MCPSettingsType.detail).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Menu(copy("选择", "Select")) {
                    Button(copy("允许搜索结果", "Allow search results")) { model.policy.connectionIDs.formUnion(model.filteredProfiles.map(\.id)) }
                    Button(copy("移除全部授权", "Remove all grants")) {
                        model.policy.connectionIDs = []; model.policy.groupIDs = []
                    }
                }.fixedSize().disabled(model.policy.allConnections)
            }
        } header: { Text(copy("连接访问", "Connection access")) }
        footer: {
            Text(model.policy.allConnections
                ? copy("包括以后新增的连接。数据库范围与执行权限仍然生效。", "Includes future connections. Database scopes and execution limits still apply.")
                : copy("勾选允许访问的连接，或按分组授权。修改后点击保存。", "Select allowed connections, or authorize a group. Save to apply changes."))
        }
        if !model.groups.isEmpty {
            Section(copy("按分组授权", "Authorize groups")) {
                Group {
                    ForEach(model.groups) { group in
                        Toggle(group.name, isOn: Binding(get: { model.policy.groupIDs.contains(group.id) }, set: { allowed in
                            if allowed { model.policy.groupIDs.insert(group.id) } else { model.policy.groupIDs.remove(group.id) }
                        })).toggleStyle(.checkbox).disabled(model.policy.allConnections)
                    }
                }
            }
        }
    }

    private func connectionLabel(_ profile: ConnectionProfile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profile.name).lineLimit(1)
            Text("\(profile.host):\(String(profile.port))").font(MCPSettingsType.detail).foregroundStyle(.secondary).lineLimit(1)
        }.help("\(profile.name)\n\(profile.host):\(String(profile.port))\n\(profile.id)")
    }

    private var connectionSelector: some View {
        Picker(copy("连接", "Connection"), selection: $model.selectedConnection) {
            if model.authorizedProfiles.isEmpty {
                Text(copy("无已授权连接", "No authorized connections")).tag(nil as UUID?)
            }
            ForEach(model.authorizedProfiles) { profile in
                Text(profile.name).tag(Optional(profile.id))
            }
        }
        .pickerStyle(.menu)
        .disabled(model.authorizedProfiles.isEmpty)
        .onAppear { selectAuthorizedConnection() }
        .onChange(of: model.authorizedProfiles.map(\.id)) { selectAuthorizedConnection() }
    }

    private func selectAuthorizedConnection() {
        if selectedProfile == nil { model.selectedConnection = model.authorizedProfiles.first?.id }
    }

    private var databaseScope: some View {
        Section {
            connectionSelector
            if let profile = selectedProfile {
                Picker(copy("访问范围", "Access scope"), selection: Binding(get: { model.rule(for: profile.id).scope }, set: { value in
                    model.updateRule(for: profile.id) { $0.databaseAccess = value }
                })) {
                    Text(copy("全部", "All")).tag(MCPDatabaseAccess.all)
                    Text(copy("仅指定名称", "Selected names only")).tag(MCPDatabaseAccess.selected)
                    Text(copy("禁止访问", "Deny access")).tag(MCPDatabaseAccess.none)
                }.pickerStyle(.menu)
                Text(scopeExplanation(profile)).font(MCPSettingsType.detail).foregroundStyle(.secondary)
                if model.rule(for: profile.id).scope == .selected {
                    TextField(copy("指定名称", "Allowed names"), text: Binding(get: {
                        model.rule(for: profile.id).databases?.sorted().joined(separator: ", ") ?? ""
                    }, set: { value in model.updateRule(for: profile.id) { $0.databases = Set(split(value)) } }))
                    .help(copy("可手动输入，以逗号分隔", "Enter names separated by commas"))
                    databasePicker(profile)
                }
            } else { unauthorizedHint }
        } header: { Text(copy("数据库与对象范围", "Database and object scope")) }
        footer: { Text(copy("切换范围会保留已选名单；指定名单为空时禁止访问。", "Changing scope preserves selected names. An empty selection denies access.")) }
    }

    private func scopeExplanation(_ profile: ConnectionProfile) -> String {
        let object: String = switch profile.databaseType {
        case .redis: copy("Redis DB 编号", "Redis DB numbers")
        case .elasticsearch: copy("Elasticsearch 索引、别名或数据流", "Elasticsearch indices, aliases or data streams")
        case .kafka: copy("Kafka Topic", "Kafka topics")
        default: copy("数据库", "Databases")
        }
        return copy("此连接按\(object)限制访问。", "This connection is scoped by: \(object).")
    }

    @ViewBuilder private var permissionOverrides: some View {
        Section {
            connectionSelector
            if let profile = selectedProfile {
                Picker(copy("权限上限", "Permission ceiling"), selection: Binding(get: { model.rule(for: profile.id).mode?.rawValue ?? "inherit" }, set: { value in
                    model.updateRule(for: profile.id) { $0.mode = MCPExecutionMode(rawValue: value) }
                })) {
                    Text(copy("继承全局", "Inherit global")).tag("inherit")
                    ForEach(MCPExecutionMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.menu)
                LabeledContent(copy("当前有效权限", "Effective access"), value: model.policy.effectiveMode(profile, database: nil).title)
                let databases = (model.rule(for: profile.id).databases ?? []).sorted()
                if !databases.isEmpty {
                    Group {
                        ForEach(databases, id: \.self) { database in
                            Picker(database, selection: Binding(get: { model.rule(for: profile.id).databaseModes[database]?.rawValue ?? "inherit" }, set: { value in
                                model.updateRule(for: profile.id) { $0.databaseModes[database] = MCPExecutionMode(rawValue: value) }
                            })) {
                                Text(copy("继承连接", "Inherit connection")).tag("inherit")
                                ForEach(MCPExecutionMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                            }.pickerStyle(.menu)
                        }
                    }
                }
            } else { unauthorizedHint }
        } header: { Text(copy("连接权限限制", "Connection permission limits")) }
        footer: { Text(copy("取全局、分组、连接、数据库规则中最严格的权限。单独设置只能收紧授权。", "The strictest global, group, connection or database rule applies. Individual limits can only narrow access.")) }
        if !model.groups.isEmpty {
            Section(copy("分组权限限制", "Group permission limits")) {
                Group {
                    ForEach(model.groups) { group in
                        Picker(group.name, selection: Binding(get: { model.policy.groupModes[group.id.uuidString]?.rawValue ?? "inherit" }, set: {
                            model.policy.groupModes[group.id.uuidString] = MCPExecutionMode(rawValue: $0)
                        })) {
                            Text(copy("继承全局", "Inherit global")).tag("inherit")
                            ForEach(MCPExecutionMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }.pickerStyle(.menu)
                    }
                }
            }
        }
    }

    private var unauthorizedHint: some View {
        Text(copy("请先在“连接”中允许至少一个连接。", "Allow at least one connection in Connections first."))
            .font(MCPSettingsType.detail).foregroundStyle(.secondary)
    }

    private func databasePicker(_ profile: ConnectionProfile) -> some View {
        let id = profile.id
        let choices = (model.databaseChoices[id] ?? []).filter {
            model.databaseSearch.isEmpty || $0.localizedCaseInsensitiveContains(model.databaseSearch)
        }
        return VStack(alignment: .leading, spacing: 8) {
            TextField(copy("搜索名称", "Search names"), text: $model.databaseSearch, prompt: Text(copy("搜索名称", "Search names")))
                .labelsHidden().textFieldStyle(.roundedBorder)
            List(choices, id: \.self) { database in
                Toggle(database, isOn: Binding(get: { model.rule(for: id).databases?.contains(database) == true }, set: { allowed in
                    model.updateRule(for: id) { rule in
                        var selected = rule.databases ?? []
                        if allowed { selected.insert(database) } else { selected.remove(database) }
                        rule.databases = selected
                    }
                })).toggleStyle(.checkbox)
            }
            .listStyle(.inset)
            .frame(height: 220)
            .overlay {
                if model.databaseChoices[id] != nil && choices.isEmpty && model.databaseChoiceErrors[id] == nil && !model.loadingDatabaseChoices.contains(id) {
                    Text(copy("没有匹配的名称", "No matching names")).font(.callout).foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            HStack {
                ProgressView().controlSize(.small).frame(width: 16, height: 16).opacity(model.loadingDatabaseChoices.contains(id) ? 1 : 0)
                Text(model.databaseChoiceErrors[id] ?? "").font(MCPSettingsType.detail).foregroundStyle(.red).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copy("从连接加载", "Load from connection")) { Task { await model.discoverDatabases(for: id) } }
                    .disabled(model.loadingDatabaseChoices.contains(id))
            }.frame(height: 44)
        }
        .onChange(of: id) { model.databaseSearch = "" }
    }

    private func split(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
