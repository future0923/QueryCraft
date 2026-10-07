import SwiftUI

struct WorkspaceKafkaTopicDetailsView: View {
    let topic: String
    let details: WorkspaceKafkaTopicDetails?
    let error: String?
    let loading: Bool
    @Bindable var editor: WorkspaceKafkaTopicConfigurationModel
    @State private var filter = ""
    private var copy: AppCopy { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(topic).font(.headline).textSelection(.enabled)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 12) {
                    metric(copy.text("分区", "Partitions"), details.map { String($0.partitions.count) } ?? "")
                    metric(copy.text("副本数", "Replication factor"), details.map { Set($0.partitions.map { $0.replicas.count }).sorted().map(String.init).joined(separator: ", ") } ?? "")
                    metric(copy.text("副本未同步分区", "Under-replicated partitions"), details.map { String($0.partitions.filter(\.isUnderReplicated).count) } ?? "")
                    metric(copy.text("清理策略", "Cleanup policy"), configuration("cleanup.policy", in: details))
                    metric(copy.text("保留时间（毫秒）", "Retention (ms)"), configuration("retention.ms", in: details))
                    metric(copy.text("保留大小（字节/分区）", "Retention (bytes/partition)"), configuration("retention.bytes", in: details))
                }.padding(.vertical, 8)
                Text(copy.text("分区与副本", "Partitions and replicas")).font(.headline)
                Table(details?.partitions ?? []) {
                    TableColumn(copy.text("分区", "Partition")) { Text(String($0.id)) }.width(65)
                    TableColumn("Leader") { Text($0.leader.map(String.init) ?? "—") }.width(85)
                    TableColumn(copy.text("副本 Broker", "Replica brokers")) { Text(ids($0.replicas)) }
                    TableColumn("ISR") { Text(ids($0.inSyncReplicas)) }
                    TableColumn(copy.text("状态", "Status")) { partition in
                        Text(partition.error ?? (partition.leader == nil ? copy.text("无 Leader", "No leader") :
                            partition.isUnderReplicated ? copy.text("副本未同步", "Under-replicated") : copy.text("正常", "OK")))
                    }
                }.monospacedDigit().frame(minHeight: 150, idealHeight: 210, maxHeight: 260)
                HStack {
                    Text(copy.text("Topic 配置", "Topic configuration")).font(.headline)
                    Spacer()
                    TextField(copy.text("搜索配置", "Search configuration"), text: $filter)
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
                WorkspaceKafkaConfigurationGrid(editor: editor, filter: filter, loading: loading)
                    .frame(minHeight: 160, maxHeight: .infinity)
                HStack(spacing: 12) {
                    Text(statusText)
                        .font(.caption).foregroundStyle(hasError ? .red : .secondary)
                        .lineLimit(1).help(statusText).textSelection(.enabled)
                    Spacer(minLength: 0)

                }
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            WorkspaceDatabaseDataProgressBar(isActive: loading || editor.isBusy)
        }
    }

    private var hasError: Bool { error != nil || details?.configurationError != nil || editor.error != nil || editor.validationMessage != nil }

    private var statusText: String {
        if let message = editor.error ?? editor.validationMessage { return message }
        if editor.isBusy { return copy.text("正在提交并回读配置…", "Committing and rereading configuration…") }
        if editor.didSave { return copy.text("已提交并回读确认", "Committed and verified") }
        if let error { return error }
        if let configurationError = details?.configurationError {
            return copy.text("配置读取失败：", "Could not read configuration: ") + configurationError
        }
        if editor.needsReload { return copy.text("使用顶部刷新重新读取配置后可编辑。", "Refresh from the top toolbar to reload configuration before editing.") }
        return copy.text("双击值直接编辑；右键恢复默认值。通过顶部工具栏预览、提交或放弃更改。",
                         "Double-click a value to edit; right-click to restore the default. Preview, commit or discard from the top toolbar.")
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).monospacedDigit().textSelection(.enabled)
        }
    }
    private func configuration(_ name: String, in details: WorkspaceKafkaTopicDetails?) -> String {
        details?.configurations.first { $0.name == name }?.value ?? "—"
    }
    private func ids(_ values: [Int32]) -> String { values.map(String.init).joined(separator: ", ") }
}
