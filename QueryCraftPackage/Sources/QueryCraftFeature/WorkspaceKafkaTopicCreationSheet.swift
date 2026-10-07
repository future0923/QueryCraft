import SwiftUI

struct WorkspaceKafkaTopicCreationSheet: View {
    let model: WorkspaceModel
    let didCreate: @MainActor (String) -> Void
    let dismiss: @MainActor () -> Void

    @State private var name = ""
    @State private var partitionsText = "1"
    @State private var replicationFactorText = "1"
    @State private var operation: Task<Void, Never>?
    @State private var errorMessage: String?
    @FocusState private var nameIsFocused: Bool

    private var busy: Bool { operation != nil }

    private var partitions: Int32? { Int32(partitionsText) }

    private var replicationFactor: Int16? { Int16(replicationFactorText) }

    private var validationMessage: String? {
        guard !name.isEmpty else {
            return AppCopy.current.text("请输入 Topic 名称。", "Enter a topic name.")
        }
        guard name.utf8.count <= 249 else {
            return AppCopy.current.text(
                "Topic 名称最多 249 个字节。",
                "Topic names can be at most 249 bytes."
            )
        }
        guard name.unicodeScalars.allSatisfy({ scalar in
            scalar.value == 46 || scalar.value == 45 || scalar.value == 95
                || (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
        }) else {
            return AppCopy.current.text(
                "Topic 名称只能包含字母、数字、点、下划线和连字符。",
                "Topic names may contain letters, numbers, dots, underscores, and hyphens."
            )
        }
        guard let partitions, (1...100_000).contains(partitions) else {
            return AppCopy.current.text(
                "分区数必须是 1 到 100000 之间的整数。",
                "Partitions must be an integer from 1 to 100000."
            )
        }
        guard let replicationFactor, (1...1_000).contains(replicationFactor) else {
            return AppCopy.current.text(
                "副本数必须是 1 到 1000 之间的整数。",
                "Replication factor must be an integer from 1 to 1000."
            )
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(
                        AppCopy.current.text("名称", "Name"),
                        text: $name,
                        prompt: Text(AppCopy.current.text("例如 orders.events", "e.g. orders.events"))
                    )
                    .focused($nameIsFocused)
                    .accessibilityIdentifier("createKafkaTopicName")
                } header: {
                    Text(AppCopy.current.text("Topic", "Topic"))
                }

                Section {
                    TextField(
                        AppCopy.current.text("分区数", "Partitions"),
                        text: $partitionsText,
                        prompt: Text("1")
                    )
                    .monospacedDigit()
                    .accessibilityIdentifier("createKafkaTopicPartitions")
                    TextField(
                        AppCopy.current.text("副本数", "Replication Factor"),
                        text: $replicationFactorText,
                        prompt: Text("1")
                    )
                    .monospacedDigit()
                    .accessibilityIdentifier("createKafkaTopicReplicationFactor")
                } header: {
                    Text(AppCopy.current.text("分区配置", "Partitioning"))
                } footer: {
                    Text(AppCopy.current.text(
                        "副本数不能超过 Kafka 集群可用的 Broker 数量。",
                        "Replication cannot exceed the available Kafka brokers."
                    ))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(busy)

            if let validationMessage, !name.isEmpty {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button(AppCopy.current.text("取消", "Cancel"), role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Button(AppCopy.current.text("创建", "Create"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || validationMessage != nil || model.connectionState != .connected)
                    .accessibilityIdentifier("createKafkaTopicSubmit")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 410)
        .interactiveDismissDisabled(busy)
        .task { nameIsFocused = true }
        .alert(
            AppCopy.current.text("无法创建 Topic", "Unable to Create Topic"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            operation?.cancel()
        }
    }

    private func submit() {
        guard !busy, validationMessage == nil, let partitions, let replicationFactor else { return }
        let requestedName = name
        operation = Task { @MainActor in
            defer { operation = nil }
            do {
                try await model.createKafkaTopic(
                    name: requestedName,
                    partitions: partitions,
                    replicationFactor: replicationFactor
                )
                try Task.checkCancellation()
                didCreate(requestedName)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

}
