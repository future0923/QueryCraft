import SwiftUI

/// Scope changes stay local until Apply; discovery only updates the model's cache.
struct MCPConnectionScopeEditor: View {
    @Bindable var model: MCPSettingsModel
    let profile: ConnectionProfile
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MCPConnectionPolicy
    @State private var search = ""
    @State private var manualNames = ""
    @State private var knownNames: Set<String>
    @State private var discoveryRevision = 0

    init(model: MCPSettingsModel, profile: ConnectionProfile) {
        self.model = model
        self.profile = profile
        // Each sheet presentation starts a new editing transaction.
        _draft = State(initialValue: model.rule(for: profile.id))
        _knownNames = State(initialValue: model.rule(for: profile.id).databases ?? [])
    }

    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    private var loading: Bool { model.loadingDatabaseChoices.contains(profile.id) }
    private var names: [String] {
        Set(model.databaseChoices[profile.id] ?? []).union(knownNames).union(draft.databases ?? [])
            .filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.sorted()
    }
    private var scope: Binding<MCPDatabaseAccess> {
        Binding(get: { draft.scope }, set: { draft.databaseAccess = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(copy("设置访问范围", "Configure object access")).font(.headline)
                Text(profile.name).fontWeight(.medium).lineLimit(1).help(profile.name)
                Text("\(profile.databaseType.title) · \(profile.host):\(String(profile.port))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(copy("允许访问的\(MCPPermissionSummary.objectKind(profile))", "Allowed \(MCPPermissionSummary.objectKind(profile))"))
                    .fontWeight(.medium)
                Picker(copy("访问范围", "Object access"), selection: scope) {
                    Text(copy("全部", "All")).tag(MCPDatabaseAccess.all)
                    Text(copy("指定名称", "Selected names")).tag(MCPDatabaseAccess.selected)
                    Text(copy("禁止访问", "Deny all")).tag(MCPDatabaseAccess.none)
                }.pickerStyle(.segmented).labelsHidden()
                if draft.scope == .selected {
                    objectControls
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: draft.scope == .all ? "checkmark.circle" : "nosign")
                            .font(.system(size: 28)).foregroundStyle(.secondary)
                        Text(draft.scope == .all
                             ? copy("允许访问此连接的全部对象", "Allow all objects in this connection")
                             : copy("不允许访问此连接的任何对象", "Deny all objects in this connection"))
                        Text(copy("仍受连接权限、全局上限和数据库账号权限限制。", "Connection access, the global limit and database account privileges still apply."))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack(spacing: 10) {
                Text(copy("应用后，在主页面检查并保存。", "Apply here, then review and save on the main page."))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Button(copy("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(copy("应用", "Apply")) {
                    model.applyObjectScope(draft, for: profile.id)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .font(MCPSettingsType.body).controlSize(.regular)
        .frame(width: 640, height: 610)
        .task(id: discoveryRevision) {
            if draft.scope == .selected && (model.databaseChoices[profile.id] == nil || discoveryRevision > 0) {
                await model.discoverDatabases(for: profile.id)
            }
        }
        .onChange(of: draft.scope) {
            if draft.scope == .selected && model.databaseChoices[profile.id] == nil { discoveryRevision += 1 }
        }
    }

    private var objectControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(copy("筛选名称", "Filter names"), text: $search)
                    .textFieldStyle(.roundedBorder).labelsHidden()
                Button(copy("从连接加载", "Load from connection")) { discoveryRevision += 1 }
                    .disabled(loading).fixedSize()
            }
            objectTable
            HStack {
                Text(copy("已选择 \((draft.databases ?? []).count) 项", "\((draft.databases ?? []).count) selected"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copy("全选当前结果", "Select results")) { draft.databases = (draft.databases ?? []).union(names) }
                    .disabled(names.isEmpty)
                Button(copy("清空选择", "Clear selection")) { draft.databases = [] }
                    .disabled(draft.databases?.isEmpty != false)
            }.font(.caption).controlSize(.small)
            loadingFeedback
            HStack(spacing: 8) {
                TextField(copy("手动添加名称，多个用逗号分隔", "Add exact names, separated by commas"), text: $manualNames)
                    .textFieldStyle(.roundedBorder).labelsHidden()
                Button(copy("添加", "Add")) { addNames() }.disabled(parsedNames.isEmpty).fixedSize()
            }
        }
    }

    private var objectTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text(copy("允许", "Allow")).frame(width: 40, alignment: .leading)
                Text(copy("名称", "Name")).frame(maxWidth: .infinity, alignment: .leading)
                Text(copy("权限限制", "Access limit")).frame(width: 165, alignment: .trailing)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 30)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(names, id: \.self) { name in
                        HStack(spacing: 8) {
                            Toggle(name, isOn: Binding(get: { draft.databases?.contains(name) == true }, set: { allowed in
                                var selected = draft.databases ?? []
                                if allowed { selected.insert(name) } else { selected.remove(name) }
                                draft.databases = selected
                            })).labelsHidden().toggleStyle(.checkbox).frame(width: 40, alignment: .leading)
                            Text(name).lineLimit(1).help(name).frame(maxWidth: .infinity, alignment: .leading)
                            permissionPicker(name).frame(width: 165, alignment: .trailing)
                        }.padding(.horizontal, 10).frame(height: 36)
                        Divider()
                    }
                }
            }
            .overlay {
                if names.isEmpty {
                    Text(emptyMessage).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(24).allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1) }
    }

    private var emptyMessage: String {
        if loading { return copy("正在读取对象名称…", "Loading object names…") }
        if model.databaseChoiceErrors[profile.id] != nil { return copy("加载失败，可重试或在下方手动添加。", "Loading failed. Retry or add names below.") }
        if model.databaseChoices[profile.id] == nil { return copy("正在准备加载…", "Preparing to load…") }
        return search.isEmpty ? copy("此连接未返回对象，可在下方手动添加。", "No objects returned. You can add names below.")
            : copy("没有匹配的名称", "No matching names")
    }

    private var loadingFeedback: some View {
        HStack(spacing: 7) {
            Text(model.databaseChoiceErrors[profile.id] ?? (loading
                 ? copy("正在加载，保留当前选择…", "Loading; current selections are preserved…")
                 : draft.databases?.isEmpty != false
                 ? copy("尚未选择对象，应用后此连接将无法访问。", "No objects selected. Applying will deny access to this connection.")
                 : copy("仅勾选的名称可访问；单项权限只能进一步收紧。", "Only checked names are accessible. Per-object limits can only narrow access.")))
                .font(.caption).foregroundStyle(model.databaseChoiceErrors[profile.id] == nil ? Color.secondary : .red)
                .lineLimit(2).help(model.databaseChoiceErrors[profile.id] ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView().controlSize(.small).frame(width: 16, height: 16).opacity(loading ? 1 : 0)
        }.frame(height: 30)
    }

    private func permissionPicker(_ name: String) -> some View {
        Picker(name, selection: Binding(get: { draft.databaseModes[name]?.rawValue ?? "inherit" }, set: { value in
            draft.databaseModes[name] = MCPExecutionMode(rawValue: value)
        })) {
            Text(copy("随连接权限", "Use connection access")).tag("inherit")
            ForEach(MCPExecutionMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
        }.labelsHidden().pickerStyle(.menu).controlSize(.small).disabled(draft.databases?.contains(name) != true)
    }

    private var parsedNames: Set<String> {
        Set(manualNames.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
    private func addNames() {
        let added = parsedNames
        knownNames.formUnion(added)
        draft.databases = (draft.databases ?? []).union(added)
        manualNames = ""
    }
}
