import SwiftUI

struct MCPOptimizationSettingsSections: View {
    @Bindable var model: MCPSettingsModel
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }

    var body: some View {
        Section {
            Picker(copy("工具发现方式", "Tool discovery"), selection: Binding(get: { model.policy.tuning.discovery }, set: { value in
                model.updateOptimizations { $0.discovery = value }
            })) {
                Text(copy("直接工具", "Direct tools")).tag(MCPToolDiscovery.flat)
                Text(copy("按需发现", "Lazy discovery")).tag(MCPToolDiscovery.lazy)
                Text(copy("两者同时", "Both")).tag(MCPToolDiscovery.both)
            }.pickerStyle(.menu)
            Text(copy("按需发现可减少工具上下文。保存后需在客户端重新加载工具。", "Lazy discovery reduces tool context. Reload tools in the client after saving."))
                .font(MCPSettingsType.detail).foregroundStyle(.secondary)
            Stepper(copy("结构缓存：\(model.policy.tuning.metadataCacheSeconds) 秒", "Metadata cache: \(model.policy.tuning.metadataCacheSeconds) seconds"), value: Binding(
                get: { model.policy.tuning.metadataCacheSeconds }, set: { value in model.updateOptimizations { $0.metadataCacheSeconds = value } }), in: 0...300, step: 10)
            Stepper(copy("元数据空闲连接：\(model.policy.tuning.maximumIdleConnections)", "Idle metadata connections: \(model.policy.tuning.maximumIdleConnections)"), value: Binding(
                get: { model.policy.tuning.maximumIdleConnections }, set: { value in model.updateOptimizations { $0.maximumIdleConnections = value } }), in: 0...8)
        } header: { Text(copy("工具发现与性能", "Tool discovery and performance")) }
        footer: {
            Text(copy("设为 0 关闭缓存或连接复用。查询结果、Redis 键和消息保持实时。", "Set to 0 to disable caching or connection reuse. Query results, Redis keys and messages remain live."))
        }
    }
}
