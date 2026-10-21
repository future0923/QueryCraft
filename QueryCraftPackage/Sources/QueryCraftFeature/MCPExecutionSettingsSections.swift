import SwiftUI

struct MCPExecutionSettingsSections: View {
    @Bindable var model: MCPSettingsModel
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }

    var body: some View {
        Section {
            TextField(copy("查询超时（秒）", "Query timeout (seconds)"), text: Binding(get: {
                model.policy.queryTimeoutSeconds.map(String.init) ?? ""
            }, set: { value in
                if value.trimmingCharacters(in: .whitespaces).isEmpty { model.policy.queryTimeoutSeconds = nil }
                else if let seconds = Int(value), (0...86400).contains(seconds) { model.policy.queryTimeoutSeconds = seconds }
            }))
            TextField(copy("最大结果行数", "Maximum result rows"), value: $model.policy.maximumRows, format: .number.grouping(.never))
            TextField(copy("结果字节上限", "Maximum result bytes"), value: $model.policy.maximumResultBytes, format: .number.grouping(.never))
            TextField(copy("会话空闲超时（秒）", "Session idle timeout (seconds)"), value: $model.policy.sessionIdleSeconds, format: .number.grouping(.never))
            Stepper(copy("每个客户端最多 \(model.policy.maximumSessions) 个会话", "Up to \(model.policy.maximumSessions) sessions per client"), value: $model.policy.maximumSessions, in: 1...128)
        } header: { Text(copy("执行与结果限制", "Execution and result limits")) }
        footer: {
            Text(copy("适用于所有 MCP 客户端。查询超时留空继承 QueryCraft 设置，0 表示不限时；这些参数不会改变连接的读写权限。", "Applies to all MCP clients. Blank timeout inherits QueryCraft settings; 0 means unlimited. These limits do not change connection permissions."))
        }
    }
}
