import SwiftUI

struct WorkspaceKafkaReadBar: View {
    let request: WorkspaceKafkaReadRequest
    let scanRequest: WorkspaceKafkaScanRequest?
    let progress: WorkspaceKafkaScanProgress?
    let isLoading: Bool
    let stop: () -> Void
    let live: WorkspaceKafkaLiveModel
    let isLive: Bool
    let startLive: (Int32?, WorkspaceKafkaScanRequest?) -> Void
    @Binding var showsJSONTable: Bool
    let rebuildJSONColumns: () -> Void
    let apply: (WorkspaceKafkaReadRequest, WorkspaceKafkaScanRequest?) -> Void

    private enum Mode: String, CaseIterable { case earliest, latest, offset, time }
    @State private var partition = ""
    @State private var mode = Mode.earliest
    @State private var offset = "0"
    @State private var count = "100"
    @State private var date = Date()
    @State private var showsFilter = false
    @State private var filterEnabled = false
    @State private var field = WorkspaceKafkaScanRequest.Field.value
    @State private var match = WorkspaceKafkaScanRequest.Match.contains
    @State private var searchText = ""
    @State private var caseSensitive = false
    @State private var maximumMessages = 10_000

    private var scanDraft: WorkspaceKafkaScanRequest? {
        guard filterEnabled else { return nil }
        return .init(field: field, match: match, text: searchText,
                     caseSensitive: caseSensitive, maximumMessages: maximumMessages)
    }

    private var copy: AppCopy { .current }
    private var draft: WorkspaceKafkaReadRequest? {
        let text = partition.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedPartition = text.isEmpty ? nil : Int32(text)
        guard text.isEmpty || selectedPartition != nil else { return nil }
        let start: WorkspaceKafkaReadRequest.Start
        switch mode {
        case .earliest: start = .earliest
        case .latest:
            guard let value = Int(count), (1...10_000).contains(value) else { return nil }
            start = .latest(value)
        case .offset:
            guard let value = Int64(offset) else { return nil }
            start = .offset(value)
        case .time: start = .timestamp(Int64(date.timeIntervalSince1970 * 1_000))
        }
        let result = WorkspaceKafkaReadRequest(partition: selectedPartition, start: start)
        return result.isValid ? result : nil
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { partitionField; positionFields; filterButton; applyButton; liveControls; displayMode; Spacer(minLength: 0); scanStatus }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) { partitionField; filterButton; applyButton; liveControls }
                HStack { positionFields; displayMode; Spacer(minLength: 0); scanStatus }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear(perform: restore)
        .onChange(of: request) { restore() }
        .onChange(of: scanRequest) { restoreFilter() }
    }

    private var displayMode: some View {
        Menu {
            Picker(copy.text("展示方式", "Display Mode"), selection: $showsJSONTable) {
                Text(copy.text("JSON 表格", "JSON Table")).tag(true)
                Text(copy.text("原始 Value", "Raw Value")).tag(false)
            }
            if showsJSONTable {
                Divider()
                Button(copy.text("重新展开字段", "Rebuild JSON Columns"), action: rebuildJSONColumns)
            }
        } label: {
            Label(showsJSONTable ? copy.text("JSON 表格", "JSON Table") : copy.text("原始 Value", "Raw Value"),
                  systemImage: showsJSONTable ? "tablecells" : "doc.plaintext")
        }
        .fixedSize()
        .help(copy.text("JSON 对象展开为列，原始 Value 保留在最后一列。实时读取时列保持固定，可重新展开字段。原始消息始终可在检查器查看。",
                       "JSON objects expand into columns; the original Value remains in the last column. Live columns stay fixed; rebuild to include new fields. The inspector always shows the original message."))
        .accessibilityIdentifier("kafkaDataDisplayMode")
    }

    private var partitionField: some View {
        HStack {
            Text(copy.text("分区", "Partition"))
            TextField(copy.text("全部", "All"), text: $partition)
                .textFieldStyle(.roundedBorder)
                .frame(width: 65)
                .accessibilityLabel(copy.text("分区编号，留空为全部", "Partition number, blank for all"))
        }
    }

    private var positionFields: some View {
        HStack(spacing: 8) {
            Picker(copy.text("起点", "Start"), selection: $mode) {
                Text(copy.text("最早", "Earliest")).tag(Mode.earliest)
                Text(copy.text("最近", "Latest")).tag(Mode.latest)
                Text("Offset").tag(Mode.offset)
                Text(copy.text("时间", "Time")).tag(Mode.time)
            }.frame(width: 150)
            switch mode {
            case .earliest: EmptyView()
            case .latest:
                TextField("100", text: $count)
                    .textFieldStyle(.roundedBorder).frame(width: 65)
                    .accessibilityLabel(copy.text("最近数量", "Recent count"))
                Text(copy.text("条 / 分区", "per partition"))
                    .foregroundStyle(.secondary)
                    .help(copy.text("按 Offset 范围读取，压缩清理后实际消息数可能更少", "Reads an offset range; compacted partitions may contain fewer messages"))
            case .offset:
                TextField("Offset", text: $offset)
                    .textFieldStyle(.roundedBorder).frame(width: 130)
                    .accessibilityLabel("Offset")
                if partition.isEmpty {
                    Text(copy.text("请指定分区", "Choose a partition")).foregroundStyle(.secondary)
                }
            case .time:
                DatePicker(copy.text("时间", "Time"), selection: $date, in: Date(timeIntervalSince1970: 0)...,
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
        }
    }

    private var applyButton: some View {
        Button(filterEnabled ? copy.text("扫描", "Scan") : copy.text("读取", "Read")) {
            if let draft { apply(draft, scanDraft) }
        }.disabled(isLoading || draft == nil || scanDraft?.isValid == false)
    }

    private var filterButton: some View {
        Group {
            if filterEnabled {
                filterTrigger.buttonStyle(.borderedProminent)
            } else {
                filterTrigger.buttonStyle(.bordered)
            }
        }
        .fixedSize()
        .accessibilityValue(filterEnabled ? copy.text("已启用", "On") : copy.text("已关闭", "Off"))
        .popover(isPresented: $showsFilter, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text(copy.text("扫描 Kafka 消息", "Scan Kafka messages")).font(.headline)
                Form {
                    Toggle(copy.text("启用过滤", "Enable filter"), isOn: $filterEnabled)
                    Picker(copy.text("字段", "Field"), selection: $field) {
                        Text("Key").tag(WorkspaceKafkaScanRequest.Field.key)
                        Text("Value").tag(WorkspaceKafkaScanRequest.Field.value)
                        Text("Key / Value").tag(WorkspaceKafkaScanRequest.Field.keyOrValue)
                    }
                    Picker(copy.text("匹配", "Match"), selection: $match) {
                        Text(copy.text("包含", "Contains")).tag(WorkspaceKafkaScanRequest.Match.contains)
                        Text(copy.text("完全相同", "Exact")).tag(WorkspaceKafkaScanRequest.Match.exact)
                    }
                    TextField(copy.text("内容", "Text"), text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Toggle(copy.text("区分大小写", "Case sensitive"), isOn: $caseSensitive)
                    Picker(copy.text("最多扫描", "Scan limit"), selection: $maximumMessages) {
                        ForEach([1_000, 10_000, 100_000], id: \.self) { value in
                            Text(value.formatted()).tag(value)
                        }
                    }
                }
                Text(copy.text("按读取栏中的分区和起点扫描。底栏“查找”仅搜索已加载的数据。扫描达到数量、约 30 秒或 64 MB 上限后停止。",
                               "Scans from the partition and start position above. Find searches loaded rows only. Stops at the message limit, about 30 seconds, or 64 MB."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(copy.text("完成", "Done")) { showsFilter = false }
                }
            }.padding(16).frame(width: 360)
        }
    }

    private var filterTrigger: some View {
        Button { showsFilter = true } label: {
            Label(copy.text("过滤", "Filter"), systemImage: "line.3.horizontal.decrease")
        }
    }

    private var liveControls: some View {
        HStack(spacing: 6) {
            Button { if let draft { startLive(draft.partition, scanDraft) } } label: {
                Label(copy.text("实时", "Live"), systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(isLoading || (isLive && live.isReading) || draft == nil || scanDraft?.isValid == false)
            .help(copy.text("从当前末尾接收新消息，沿用分区和过滤条件；保留最近 1 万条或 32 MB", "Receive new messages from the current end using this partition and filter; retains up to 10,000 rows or 32 MB"))
            if isLive {
                Button(live.isReading ? copy.text("暂停", "Pause") : copy.text("继续", "Resume")) {
                    if live.isReading { live.pause() } else { live.resume() }
                }.disabled(live.mode == .stopped)
                Button(copy.text("回到最新", "Latest")) { live.showLatest() }
                    .disabled(live.page?.rowCount == 0)
                Button { live.stop() } label: { Image(systemName: "stop.circle") }
                    .accessibilityLabel(copy.text("停止实时读取", "Stop live reading"))
                    .disabled(!live.isReading && live.mode != .paused)
            }
        }
    }

    private var scanStatus: some View {
        HStack(spacing: 6) {
            Text(statusText)
                .font(.caption).foregroundStyle((isLive ? live.error != nil : progress?.status == .failed) ? .red : .secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(statusText + ((isLive ? live.error : progress?.error).map { "\n" + $0 } ?? ""))
            Button(action: stop) { Image(systemName: "stop.circle") }
                .buttonStyle(.plain)
                .accessibilityLabel(copy.text("停止读取", "Stop reading"))
                .disabled(!isLoading || isLive)
                .opacity(isLoading && !isLive ? 1 : 0)
        }.frame(width: 235, alignment: .trailing)
    }

    private var statusText: String {
        if isLive {
            let status: String = switch live.mode {
            case .idle: ""
            case .starting: copy.text("连接中", "Connecting")
            case .running: copy.text("接收中", "Live")
            case .paused: copy.text("已暂停", "Paused")
            case .stopped: copy.text("已停止", "Stopped")
            case .failed: copy.text("连接中断", "Connection interrupted")
            }
            return copy.text("\(status) · 接收 \(live.received) · 匹配 \(live.matched) · 淘汰 \(live.discarded)",
                             "\(status) · Received \(live.received) · Matched \(live.matched) · Evicted \(live.discarded)")
        }
        guard let progress else { return "" }
        let counts = copy.text("扫描 \(progress.scanned) · 匹配 \(progress.matched)",
                               "Scanned \(progress.scanned) · Matched \(progress.matched)")
        let reason: String = switch progress.status {
        case .scanning: copy.text("扫描中", "Scanning")
        case .reachedEnd: copy.text("已到末尾", "End reached")
        case .messageLimit: copy.text("数量上限", "Message limit")
        case .timeLimit: copy.text("时间上限", "Time limit")
        case .byteLimit: copy.text("容量上限", "Size limit")
        case .cancelled: copy.text("已停止，保留原结果", "Stopped; previous results kept")
        case .failed: copy.text("失败，保留原结果", "Failed; previous results kept")
        }
        return counts + " · " + reason
    }

    private func restore() {
        restoreFilter()
        partition = request.partition.map(String.init) ?? ""
        switch request.start {
        case .earliest: mode = .earliest
        case .latest(let value): mode = .latest; count = String(value)
        case .offset(let value): mode = .offset; offset = String(value)
        case .timestamp(let value): mode = .time; date = Date(timeIntervalSince1970: Double(value) / 1_000)
        }
    }

    private func restoreFilter() {
        filterEnabled = scanRequest != nil
        guard let scanRequest else { return }
        field = scanRequest.field
        match = scanRequest.match
        searchText = scanRequest.text
        caseSensitive = scanRequest.caseSensitive
        maximumMessages = scanRequest.maximumMessages
    }
}
