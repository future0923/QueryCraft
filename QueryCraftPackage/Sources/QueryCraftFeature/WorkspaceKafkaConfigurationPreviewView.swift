import SwiftUI

struct WorkspaceKafkaConfigurationPreviewView: View {
    let topic: String
    let changes: [WorkspaceKafkaTopicConfigurationChange]
    let dismiss: @MainActor () -> Void
    private var copy: AppCopy { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(copy.text("配置更改预览", "Configuration Changes")).font(.headline)
                Spacer()
                Button(copy.text("关闭", "Close"), action: dismiss)
            }
            Text(topic).textSelection(.enabled)
            Table(changes) {
                TableColumn(copy.text("配置项", "Property")) { Text($0.id).textSelection(.enabled) }
                TableColumn(copy.text("修改前", "Before")) { change in
                    Text((change.original.value ?? "—") + (change.original.isDefault ? copy.text("（继承）", " (inherited)") : ""))
                        .textSelection(.enabled)
                }
                TableColumn(copy.text("修改后", "After")) { Text($0.value ?? copy.text("继承默认值", "Inherit default")).textSelection(.enabled) }
            }.alternatingRowBackgrounds(.disabled)
            Text(copy.text("仅提交以上配置项；恢复默认值会移除 Topic 覆盖。", "Only these properties will be submitted. Restoring defaults removes topic overrides."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 760, height: 360)
    }
}
