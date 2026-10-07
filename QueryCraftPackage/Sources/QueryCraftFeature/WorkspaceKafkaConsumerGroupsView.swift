import SwiftUI

struct WorkspaceKafkaConsumerGroupsView: View {
    let topic: String
    let model: WorkspaceModel
    let openMessages: (WorkspaceKafkaReadRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [WorkspaceKafkaConsumerGroup] = []
    @State private var selection: String?
    @State private var filter = ""
    @State private var manualGroupID = ""
    @State private var offsets: [WorkspaceKafkaConsumerOffset] = []
    @State private var groupsError: String?
    @State private var offsetsError: String?
    @State private var loadingGroups = true
    @State private var loadingOffsets = false
    @State private var hasLoadedGroups = false
    @State private var offsetsGroupID: String?
    @State private var selectedPartition: Int32?
    @State private var selectedDetail = Detail.offsets
    @State private var refreshID = UUID()
    @State private var memberships: [String: WorkspaceKafkaGroupTopicMembership] = [:]
    @State private var checkingMemberships = false
    @State private var automaticRefresh = false
    @State private var lastUpdated: Date?
    @State private var offsetRequestID = UUID()
    @State private var groupRequestID = UUID()
    @State private var membershipRequestID = UUID()
    private var copy: AppCopy { .current }
    private enum Detail: Hashable { case offsets, members }

    private struct OffsetRequest: Equatable {
        let groupID: String?
        let refreshID: UUID
    }

    private struct MembershipRequest: Equatable {
        let groups: [String]
        let refreshID: UUID
    }

    private struct AutomaticRequest: Equatable {
        let groupID: String?
        let enabled: Bool
        let detail: Detail
    }

    private var sortedGroups: [WorkspaceKafkaConsumerGroup] {
        groups.filter { filter.isEmpty || $0.id.localizedCaseInsensitiveContains(filter) }.sorted {
            let left = memberships[$0.id] ?? .unknown
            let right = memberships[$1.id] ?? .unknown
            return left != right ? left.rawValue < right.rawValue : $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    // Selection can change before its task starts; never show the previous group's rows.
    private var displayedOffsets: [WorkspaceKafkaConsumerOffset] {
        offsetsGroupID == selection ? offsets : []
    }

    private var hasCurrentOffsets: Bool { selection != nil && offsetsGroupID == selection && lastUpdated != nil }

    private var selectedReadRequest: WorkspaceKafkaReadRequest? {
        guard selectedDetail == .offsets, !loadingGroups, !loadingOffsets, offsetsError == nil else { return nil }
        return displayedOffsets.first { $0.partition == selectedPartition }?.pendingMessagesReadRequest
    }

    private var openMessagesHelp: String {
        guard let request = selectedReadRequest, let partition = request.partition,
              case let .offset(offset) = request.start else {
            return copy.text("选择有已知积压的分区以查看消息", "Select a partition with known lag to view messages")
        }
        return copy.text("从分区 \(partition) 的 Offset \(offset) 开始查看，不修改消费组进度",
                         "Read partition \(partition) from offset \(offset) without changing the group's position")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.text("消费组", "Consumer Groups")).font(.headline)
                    Text(topic).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Toggle(copy.text("自动刷新（15 秒）", "Auto refresh (15s)"), isOn: $automaticRefresh)
                    .toggleStyle(.checkbox)
                Button { refreshID = UUID() } label: {
                    Label(copy.text("刷新", "Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(loadingGroups || loadingOffsets)
                Button(copy.text("完成", "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            HSplitView {
                groupList.frame(minWidth: 200, idealWidth: 240, maxWidth: 320, maxHeight: .infinity)
                offsetTable.frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            WorkspaceDatabaseDataProgressBar(isActive: loadingGroups || loadingOffsets || checkingMemberships)
            HStack(spacing: 12) {
                Text(copy.text("Lag 是末尾 Offset 与已提交 Offset 的差值；压缩清理后的 Topic 不一定等于实际消息数。",
                               "Lag is the difference between the end and committed offsets; compacted topics may contain fewer messages."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(copy.text("查看积压消息", "View Pending Messages"), systemImage: "text.magnifyingglass") {
                    guard let request = selectedReadRequest else { return }
                    openMessages(request)
                }
                .disabled(selectedReadRequest == nil)
                .help(openMessagesHelp)
                .accessibilityIdentifier("kafkaViewPendingMessagesButton")
                .fixedSize()
            }.padding(12)
        }
        .frame(minWidth: 1040, idealWidth: 1040, maxWidth: .infinity,
               minHeight: 540, idealHeight: 660, maxHeight: .infinity, alignment: .top)
        .task(id: refreshID) { await loadGroups() }
        .task(id: OffsetRequest(groupID: selection, refreshID: refreshID)) { await loadOffsets() }
        .task(id: MembershipRequest(groups: groups.map(\.id), refreshID: refreshID)) { await loadMemberships() }
        .task(id: AutomaticRequest(groupID: selection, enabled: automaticRefresh, detail: selectedDetail)) {
            guard automaticRefresh, selection != nil, selectedDetail == .offsets else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(15))
                    if !loadingOffsets && !loadingGroups { await loadOffsets() }
                }
            } catch { /* Closing the sheet or disabling refresh cancels the timer. */ }
        }
    }

    private var groupList: some View {
        VStack(spacing: 8) {
            TextField(copy.text("搜索消费组", "Search groups"), text: $filter)
                .textFieldStyle(.roundedBorder).padding([.horizontal, .top], 12)
            HStack {
                Text(copy.text("已确认关联：\(memberships.values.filter { $0 == .related }.count) 个组",
                               "Confirmed related: \(memberships.values.filter { $0 == .related }.count) groups"))
            }.font(.caption).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(sortedGroups) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.id).lineLimit(1).help(group.id)
                        HStack {
                            Text(group.state)
                            Spacer()
                            if memberships[group.id] == .related {
                                Text(copy.text("当前 Topic", "This topic")).foregroundStyle(.tint)
                            } else if memberships[group.id] == nil || memberships[group.id] == .unknown {
                                Text(copy.text("待确认", "Unconfirmed"))
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.tag(group.id)
                }
            }
            .overlay {
                if groups.isEmpty && hasLoadedGroups && !loadingGroups && groupsError == nil {
                    Text(copy.text("暂无可见消费组", "No visible consumer groups"))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 8) {
                Text(groupsError ?? " ").font(.caption).foregroundStyle(.red)
                    .lineLimit(1).help(groupsError ?? "").textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField(copy.text("或输入消费组 ID", "Or enter a group ID"), text: $manualGroupID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(openManualGroup)
                Button(copy.text("查看", "View"), action: openManualGroup)
                    .disabled(manualGroupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(12)
        }
    }

    private var offsetTable: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(selection ?? copy.text("消费位置", "Consumer offsets")).font(.headline).textSelection(.enabled)
                    Spacer()
                    Picker(copy.text("消费组详情", "Group details"), selection: $selectedDetail) {
                        Text(copy.text("积压", "Lag")).tag(Detail.offsets)
                        Text(copy.text("成员", "Members")).tag(Detail.members)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                }
                if selectedDetail == .members {
                    WorkspaceKafkaConsumerMembersView(groupID: selection, topic: topic, model: model,
                        refreshID: refreshID, automaticRefresh: automaticRefresh)
                        .id(selection)
                } else {
                let summary = WorkspaceKafkaLagSummary(offsets: displayedOffsets)
                HStack(spacing: 20) {
                    Text(copy.text("总 Lag：\(number(summary.totalLag))", "Total lag: \(number(summary.totalLag))"))
                    Text(copy.text("积压分区：\(hasCurrentOffsets ? String(summary.laggingPartitions) : "—")",
                                   "Lagging partitions: \(hasCurrentOffsets ? String(summary.laggingPartitions) : "—")"))
                    if summary.unknownPartitions > 0 {
                        Text(copy.text("未知：\(summary.unknownPartitions) · 已知 Lag：\(number(summary.knownLag))",
                                       "Unknown: \(summary.unknownPartitions) · Known lag: \(number(summary.knownLag))"))
                    }
                }.font(.callout).monospacedDigit()
                Table(displayedOffsets, selection: $selectedPartition) {
                    TableColumn(copy.text("分区", "Partition")) { Text(String($0.partition)) }.width(55)
                    TableColumn(copy.text("已提交 Offset", "Committed Offset")) { Text(number($0.committedOffset)) }
                        .width(min: 95, ideal: 110)
                    TableColumn(copy.text("起始 Offset", "Start Offset")) { Text(number($0.beginningOffset)) }
                        .width(min: 85, ideal: 105)
                    TableColumn(copy.text("末尾 Offset", "End Offset")) { Text(number($0.endOffset)) }
                        .width(min: 85, ideal: 105)
                    TableColumn("Lag") { Text(number($0.lag)) }.width(min: 50, ideal: 70, max: 90)
                    TableColumn(copy.text("状态", "Status")) { row in
                        Text(status(row)).help(status(row)).foregroundStyle(row.lag == nil ? .secondary : .primary)
                    }
                    .width(min: 100, ideal: 150)
                }
                .monospacedDigit()
                .overlay {
                    if hasCurrentOffsets && displayedOffsets.isEmpty && !loadingOffsets && offsetsError == nil {
                        Text(copy.text("此 Topic 暂无分区数据", "No partition data for this topic")).foregroundStyle(.secondary)
                    } else if selection == nil && hasLoadedGroups && !loadingGroups && !checkingMemberships {
                        Text(copy.text("选择消费组以查看消费位置与积压", "Select a group to view offsets and lag"))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(offsetsError ?? (hasCurrentOffsets
                        ? copy.text("\(displayedOffsets.count) 个分区", "\(displayedOffsets.count) partitions") : " "))
                        .foregroundStyle(offsetsError == nil ? Color.secondary : Color.red)
                        .lineLimit(1).help(offsetsError ?? "").textSelection(.enabled)
                    Spacer()
                    if hasCurrentOffsets, let lastUpdated {
                        Text(copy.text("更新于 ", "Updated ") + lastUpdated.formatted(date: .omitted, time: .standard))
                    }
                }.font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12)
    }

    private func number(_ value: Int64?) -> String { value.map(String.init) ?? "—" }

    private func status(_ row: WorkspaceKafkaConsumerOffset) -> String {
        if let error = row.error { return error }
        if row.committedOffset == nil { return copy.text("未提交", "Not committed") }
        if row.isOutsideLog { return copy.text("超出日志范围", "Outside log range") }
        if row.lag == nil { return copy.text("未知", "Unknown") }
        return copy.text("正常", "OK")
    }

    private func openManualGroup() {
        let id = manualGroupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        selection = id
    }

    private func loadGroups() async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        groupRequestID = requestID
        loadingGroups = true
        defer { if groupRequestID == requestID { loadingGroups = false } }
        groupsError = nil
        do {
            let result = try await model.fetchKafkaConsumerGroups()
            try Task.checkCancellation()
            guard groupRequestID == requestID else { return }
            groups = result
            hasLoadedGroups = true
        } catch {
            guard !Task.isCancelled, groupRequestID == requestID else { return }
            groupsError = error.localizedDescription
        }
    }

    private func loadOffsets() async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        offsetRequestID = requestID
        if offsetsGroupID != selection {
            offsets = []
            lastUpdated = nil
            offsetsGroupID = selection
            selectedPartition = nil
        }
        offsetsError = nil
        guard let selection else { loadingOffsets = false; return }
        loadingOffsets = true
        defer { if offsetRequestID == requestID { loadingOffsets = false } }
        do {
            let result = try await model.fetchKafkaConsumerOffsets(groupID: selection, topic: topic)
            try Task.checkCancellation()
            guard offsetRequestID == requestID else { return }
            offsets = result
            lastUpdated = Date()
            if !result.contains(where: { $0.partition == selectedPartition }) {
                selectedPartition = result.first { $0.pendingMessagesReadRequest != nil }?.partition
            }
            if result.contains(where: { $0.committedOffset != nil && $0.error == nil }) { memberships[selection] = .related }
        } catch {
            guard !Task.isCancelled, offsetRequestID == requestID else { return }
            offsetsError = error.localizedDescription
        }
    }

    private func loadMemberships() async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        membershipRequestID = requestID
        let groupIDs = Set(groups.map(\.id))
        memberships = memberships.filter { groupIDs.contains($0.key) }
        checkingMemberships = !groups.isEmpty
        defer { if membershipRequestID == requestID { checkingMemberships = false } }
        guard !groups.isEmpty else { return }
        let deadline = Date().addingTimeInterval(20)
        for group in groups {
            guard !Task.isCancelled, Date() < deadline else { break }
            do {
                let membership = try await model.fetchKafkaGroupTopicMembership(groupID: group.id, topic: topic)
                try Task.checkCancellation()
                guard membershipRequestID == requestID else { return }
                memberships[group.id] = membership
                if selection == nil, membership == .related { selection = group.id }
            } catch {
                guard !Task.isCancelled, membershipRequestID == requestID else { return }
                memberships[group.id] = .unknown
            }
        }
    }
}
