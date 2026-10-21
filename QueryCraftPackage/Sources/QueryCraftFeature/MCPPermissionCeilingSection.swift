import SwiftUI

struct MCPPermissionCeilingSection: View {
    @Bindable var model: MCPSettingsModel
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }

    var body: some View {
        Section {
            Toggle(copy("统一收紧所有连接的权限", "Apply an additional limit to all connections"), isOn: Binding(
                get: { model.policy.mode != .fullAccess }, set: { model.setGlobalCeilingEnabled($0) }))
            if model.policy.mode != .fullAccess {
                Picker(copy("所有连接最多允许", "Global permission ceiling"), selection: $model.policy.mode) {
                    ForEach(MCPExecutionMode.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
            }
            Text(copy("原来的“全局执行权限”在这里。已有规则按原值保留；更改分组权限不会自动放宽此上限。", "This is the original global execution permission. Existing values are preserved; editing a group never automatically raises this ceiling."))
                .font(MCPSettingsType.detail).foregroundStyle(.secondary)
        } header: { Text(copy("额外权限上限", "Global permission ceiling")) }
        footer: {
            Text(copy("关闭额外限制相当于将全局上限设为完整访问，各分组、连接、对象和工具仍按自己的规则检查。保存前请核对最终权限。", "Turning this off sets the global ceiling to full access. Group, connection, object and tool rules still apply. Review effective access before saving."))
        }
    }
}
