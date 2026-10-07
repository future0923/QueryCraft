import SwiftUI

struct WorkspaceKafkaConsumerMembersView: View {
    let groupID: String?
    let topic: String
    let model: WorkspaceModel
    let refreshID: UUID
    let automaticRefresh: Bool
    @State private var details: WorkspaceKafkaConsumerGroupDetails?
    @State private var error: String?
    @State private var loading = false
    @State private var lastUpdated: Date?
    @State private var requestID = UUID()
    private var copy: AppCopy { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                Text(copy.text("成员：\(details.map { String($0.members.count) } ?? "—")",
                               "Members: \(details.map { String($0.members.count) } ?? "—")"))
                Text(copy.text("状态：", "State: ") + (details?.state ?? "—"))
                Text(copy.text("分配策略：", "Assignor: ") + (details?.assignor.nonEmpty ?? "—"))
            }.font(.callout).lineLimit(1)
            Table(details?.members ?? []) {
                TableColumn("Client ID") { Text($0.clientID).textSelection(.enabled).help($0.clientID) }
                TableColumn(copy.text("主机", "Host")) { Text($0.host).textSelection(.enabled) }
                TableColumn(copy.text("当前 Topic 分区", "Topic partitions")) { member in
                    Text(member.partitions.isEmpty ? "—" : member.partitions.map(String.init).joined(separator: ", "))
                        .help(member.partitions.isEmpty ? copy.text("未分配当前 Topic 的分区", "No assignment for this topic") : topic)
                }.width(min: 90, ideal: 120)
                TableColumn("Member ID") { Text($0.id).textSelection(.enabled).help($0.id) }
                TableColumn("Instance ID") { Text($0.instanceID ?? "—").textSelection(.enabled).help($0.instanceID ?? "") }
            }
            .overlay {
                if let details, details.members.isEmpty, !loading, error == nil {
                    Text(copy.text("当前没有在线成员", "No active members")).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(error ?? copy.text("分区分配仅展示当前 Topic", "Assignments shown for the current topic"))
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .lineLimit(1).help(error ?? "").textSelection(.enabled)
                Spacer()
                if let lastUpdated {
                    Text(copy.text("更新于 ", "Updated ") + lastUpdated.formatted(date: .omitted, time: .standard))
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .overlay(alignment: .bottom) {
            WorkspaceDatabaseDataProgressBar(isActive: loading).offset(y: 10)
        }
        .task(id: refreshID) {
            guard let groupID else { return }
            await load(groupID: groupID)
        }
        .task(id: automaticRefresh) {
            guard automaticRefresh, let groupID else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(15))
                    if !loading { await load(groupID: groupID) }
                }
            } catch { /* The view's lifetime owns refresh cancellation. */ }
        }
    }

    private func load(groupID: String) async {
        guard !Task.isCancelled else { return }
        let currentRequestID = UUID()
        requestID = currentRequestID
        loading = true
        error = nil
        defer { if requestID == currentRequestID { loading = false } }
        do {
            let result = try await model.fetchKafkaConsumerGroupDetails(groupID: groupID, topic: topic)
            try Task.checkCancellation()
            guard requestID == currentRequestID else { return }
            details = result
            lastUpdated = Date()
        } catch {
            guard !Task.isCancelled, requestID == currentRequestID else { return }
            self.error = error.localizedDescription
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
