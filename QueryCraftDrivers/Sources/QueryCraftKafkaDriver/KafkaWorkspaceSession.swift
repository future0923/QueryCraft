import Foundation
import QueryCraftFeature

actor KafkaWorkspaceSession: WorkspaceSession,
    WorkspaceSessionCapabilityProviding,
    WorkspaceTopicCreationProviding,
    WorkspaceKafkaTopicDeleting,
    WorkspaceKafkaReading,
    WorkspaceKafkaScanning,
    WorkspaceKafkaTailing,
    WorkspaceKafkaProducing,
    WorkspaceKafkaMessageCopying,
    WorkspaceKafkaConsumerGroupProviding,
    WorkspaceKafkaConsumerGroupDetailsProviding,
    WorkspaceKafkaAuthenticationConfiguring,
    WorkspaceKafkaTopicDetailsProviding,
    WorkspaceKafkaTopicConfigurationEditing,
    WorkspaceKafkaGroupTopicMembershipProviding
{
    let capabilities = WorkspaceSessionCapabilities.kafka

    private static let maximumFetchCycles = 20
    private static let maximumSortedFetchCycles = 20
    private static let maximumCountMessages = 10_000

    private struct TopicCache: Sendable {
        var messages: [KafkaMessage] = []
        var nextOffsets: [Int32: Int64] = [:]
        var exhausted: Set<Int32> = []
    }

    private var configuration: KafkaConnectionConfiguration
    private let makeClient: (@Sendable () -> any KafkaClient)?
    private var client: (any KafkaClient)?
    private var readRequests: [String: WorkspaceKafkaReadRequest] = [:]
    private var completedScans: [String: (WorkspaceKafkaScanRequest, WorkspaceKafkaScanProgress)] = [:]
    private var scanIDs: [String: UUID] = [:]
    private var connected = false
    private var topics: [String: KafkaTopicMetadata] = [:]
    private var brokers: [Int32: KafkaBrokerAddress] = [:]
    private var caches: [String: TopicCache] = [:]

    init(
        configuration: KafkaConnectionConfiguration,
        makeClient: (@Sendable () -> any KafkaClient)? = nil
    ) {
        self.configuration = configuration
        self.makeClient = makeClient
    }

    func configureSASL(_ mechanism: KafkaSASLMechanism) async throws {
        guard !connected, client == nil else {
            throw KafkaError.invalidConfiguration("SASL mechanism must be set before connecting")
        }
        configuration.saslMechanism = mechanism
    }

    func connect() async throws {
        try await LicenseAccessGate.shared.requireDatabaseAccess()
        try Task.checkCancellation()
        if connected, client?.isConnected() == true { return }
        client?.close()
        client = nil
        connected = false
        topics.removeAll()
        brokers.removeAll()
        caches.removeAll()
        readRequests.removeAll()
        completedScans.removeAll()
        scanIDs.removeAll()
        let newClient = makeClient?() ?? KafkaRdkafkaClient(configuration: configuration)
        do {
            try newClient.connect()
            client = newClient
            connected = true
            try await refreshMetadata()
            try Task.checkCancellation()
        } catch {
            newClient.close()
            client = nil
            connected = false
            throw error
        }
    }

    func isConnected() async -> Bool {
        connected && client?.isConnected() == true
    }

    func fetchConsumerGroups() async throws -> [WorkspaceKafkaConsumerGroup] {
        try Task.checkCancellation()
        try requireConnection()
        guard let client else { throw WorkspaceSessionError.notConnected }
        return try client.consumerGroups()
    }

    func fetchConsumerOffsets(groupID: String, topic: String) async throws -> [WorkspaceKafkaConsumerOffset] {
        try Task.checkCancellation()
        try requireConnection()
        guard let client else { throw WorkspaceSessionError.notConnected }
        return try client.consumerOffsets(groupID: groupID, topic: topic)
    }

    func fetchConsumerGroupDetails(groupID: String, topic: String) async throws -> WorkspaceKafkaConsumerGroupDetails {
        try Task.checkCancellation()
        try requireConnection()
        guard let client else { throw WorkspaceSessionError.notConnected }
        return try client.consumerGroupDetails(groupID: groupID, topic: topic)
    }

    func fetchTopicDetails(topic: String) async throws -> WorkspaceKafkaTopicDetails {
        try Task.checkCancellation()
        try requireConnection()
        guard let client else { throw WorkspaceSessionError.notConnected }
        return try client.topicDetails(topic: topic)
    }

    func updateTopicConfiguration(_ request: WorkspaceKafkaTopicConfigurationRequest) async throws {
        try Task.checkCancellation()
        try requireConnection()
        try request.validate()
        guard let client else { throw WorkspaceSessionError.notConnected }
        let current = try client.topicDetails(topic: request.topic)
        guard current.configurationError == nil else { throw WorkspaceKafkaTopicConfigurationError.unavailable }
        try request.validateCurrent(current.configurations)
        try Task.checkCancellation()
        try client.updateTopicConfiguration(request)
    }

    func fetchGroupTopicMembership(groupID: String, topic: String) async throws -> WorkspaceKafkaGroupTopicMembership {
        try Task.checkCancellation()
        try requireConnection()
        guard let client, let metadata = topics[topic] else {
            throw WorkspaceSessionError.metadataUnavailable(object: topic)
        }
        return try client.groupTopicMembership(groupID: groupID, topic: topic, partitions: metadata.partitions.map(\.partition))
    }

    func prepareReading(topic: String, request: WorkspaceKafkaReadRequest) async throws {
        try Task.checkCancellation()
        try requireConnection()
        guard request.isValid, let client else {
            throw WorkspaceSessionError.invalidPageRequest
        }
        guard readRequests[topic] != request else { return }
        let offsets = try client.startingOffsets(topic: topic, request: request)
        try Task.checkCancellation()
        guard let metadata = topics[topic] else {
            throw WorkspaceSessionError.metadataUnavailable(object: topic)
        }
        caches[topic] = TopicCache(
            nextOffsets: offsets,
            exhausted: Set(metadata.partitions.map(\.partition)).subtracting(offsets.keys)
        )
        readRequests[topic] = request
        completedScans[topic] = nil
        scanIDs[topic] = nil
    }

    func prepareScanning(
        topic: String,
        request: WorkspaceKafkaScanRequest,
        onProgress: @escaping @Sendable (WorkspaceKafkaScanProgress) async -> Void
    ) async throws {
        try Task.checkCancellation()
        try requireConnection()
        guard request.isValid, let client, let metadata = topics[topic] else {
            throw WorkspaceSessionError.invalidPageRequest
        }
        if let (previousRequest, progress) = completedScans[topic], previousRequest == request {
            await onProgress(progress)
            return
        }
        let scanID = UUID()
        scanIDs[topic] = scanID
        defer { if scanIDs[topic] == scanID { scanIDs[topic] = nil } }
        // Work locally and publish only after a successful bounded scan. Cancelled
        // or failed scans must not replace the previous browsing cache.
        let readRequest = readRequests[topic] ?? WorkspaceKafkaReadRequest()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var offsets = try client.startingOffsets(topic: topic, request: readRequest)
        var matches: [KafkaMessage] = []
        var scanned = 0
        var bytes = 0
        var status = WorkspaceKafkaScanProgress.Status.scanning
        let byteLimit = 64 * 1_024 * 1_024
        while !offsets.isEmpty {
            try Task.checkCancellation()
            guard self.client === client, scanIDs[topic] == scanID else { throw CancellationError() }
            if scanned >= request.maximumMessages { status = .messageLimit; break }
            if ContinuousClock.now >= deadline { status = .timeLimit; break }
            let response = try client.fetch(topic: topic, offsets: offsets,
                                            maximumMessages: min(1_000, request.maximumMessages - scanned))
            try Task.checkCancellation()
            for message in response.messages {
                guard let start = offsets[message.partition], message.offset >= start else { continue }
                if scanned >= request.maximumMessages { status = .messageLimit; break }
                bytes += message.key?.count ?? 0
                bytes += message.value?.count ?? 0
                for header in message.headers {
                    bytes += header.key.utf8.count
                    bytes += header.value?.count ?? 0
                }
                if bytes > byteLimit { status = .byteLimit; break }
                scanned += 1
                if request.matches(key: Self.displayText(message.key), value: Self.displayText(message.value)) {
                    matches.append(message)
                }
            }
            let previousOffsets = offsets
            for partition in Array(offsets.keys) {
                if response.exhausted.contains(partition) {
                    offsets[partition] = nil
                } else if let next = response.nextOffsets[partition] {
                    offsets[partition] = max(offsets[partition] ?? 0, next)
                }
            }
            if status == .scanning {
                if offsets.isEmpty { status = .reachedEnd }
                else if scanned >= request.maximumMessages { status = .messageLimit }
            }
            await onProgress(.init(scanned: scanned, matched: matches.count, status: status))
            try Task.checkCancellation()
            guard self.client === client, scanIDs[topic] == scanID else { throw CancellationError() }
            if status != .scanning { break }
            guard offsets != previousOffsets else {
                throw KafkaError.network("Kafka scan made no progress; retry the scan")
            }
        }
        if status == .scanning { status = .reachedEnd }
        let progress = WorkspaceKafkaScanProgress(scanned: scanned, matched: matches.count, status: status)
        try Task.checkCancellation()
        guard self.client === client, scanIDs[topic] == scanID else { throw CancellationError() }
        caches[topic] = TopicCache(messages: matches, exhausted: Set(metadata.partitions.map(\.partition)))
        completedScans[topic] = (request, progress)
        await onProgress(progress)
    }

    func fetchDatabases() async throws -> [String] {
        try requireConnection()
        return ["Kafka"]
    }

    func tailStartingOffsets(topic: String, partition: Int32?) async throws -> [Int32: Int64] {
        try Task.checkCancellation()
        try requireConnection()
        guard let client else { throw WorkspaceSessionError.notConnected }
        return try client.tailStartingOffsets(topic: topic, partition: partition)
    }

    func pollTail(topic: String, offsets: [Int32: Int64], filter: WorkspaceKafkaScanRequest?) async throws -> WorkspaceKafkaTailBatch {
        try Task.checkCancellation()
        try requireConnection()
        guard let client, !offsets.isEmpty, offsets.allSatisfy({ $0.key >= 0 && $0.value >= 0 }), filter?.isValid != false else {
            throw WorkspaceSessionError.invalidPageRequest
        }
        let result = try client.pollTail(topic: topic, offsets: offsets)
        try Task.checkCancellation()
        let rows = result.messages.filter { message in
            filter?.matches(key: Self.displayText(message.key), value: Self.displayText(message.value)) ?? true
        }.map(Self.row)
        return .init(data: .init(columns: Self.dataColumns, rows: rows),
                     received: result.messages.count, nextOffsets: result.nextOffsets)
    }

    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] {
        try requireConnection()
        guard database == "Kafka" else { return [] }
        try await refreshMetadata()
        return Self.sortedTopics(Array(topics.values))
            .map { topic in
                WorkspaceDatabaseObject(
                    name: topic.name,
                    kind: .table,
                    summary: WorkspaceDatabaseObjectSummary(
                        documentCount: nil,
                        storageByteCount: nil,
                        health: nil
                    )
                )
            }
    }

    func createTopic(
        name: String,
        partitions: Int32,
        replicationFactor: Int16
    ) async throws {
        try requireConnection()
        guard databaseNameIsValid(name), partitions > 0, replicationFactor > 0 else {
            throw KafkaError.network("Topic name, partitions, and replication factor must be valid")
        }
        guard let client else { throw WorkspaceSessionError.notConnected }
        try client.createTopic(
            name: name,
            partitions: partitions,
            replicationFactor: replicationFactor
        )
        caches[name] = nil
        try await refreshMetadata()
    }

    func deleteTopic(name: String) async throws {
        try Task.checkCancellation()
        try requireConnection()
        try WorkspaceKafkaTopicDeletionRequest(topic: name).validate()
        guard let client else { throw WorkspaceSessionError.notConnected }
        try client.deleteTopic(name: name)
        topics[name] = nil
        caches[name] = nil
        readRequests[name] = nil
        completedScans[name] = nil
        scanIDs[name] = nil
    }

    func messageForCopy(_ reference: WorkspaceKafkaMessageReference) async throws -> WorkspaceKafkaMessagePayload {
        try Task.checkCancellation()
        try requireConnection()
        guard databaseNameIsValid(reference.topic), reference.partition >= 0, reference.offset >= 0, let client else {
            throw KafkaError.network("Invalid message location")
        }
        let result = try client.fetch(topic: reference.topic, offsets: [reference.partition: reference.offset], maximumMessages: 1)
        try Task.checkCancellation()
        guard let message = result.messages.first(where: {
            $0.partition == reference.partition && $0.offset == reference.offset
        }) else { throw WorkspaceKafkaMessageCopyError.unavailable }
        return .init(key: message.key, value: message.value,
                     headers: message.headers.map { .init(name: $0.key, value: $0.value) })
    }

    func produce(_ request: WorkspaceKafkaProduceRequest) async throws -> WorkspaceKafkaProduceReceipt {
        try Task.checkCancellation()
        try requireConnection()
        try request.validate()
        guard let client else { throw WorkspaceSessionError.notConnected }
        let receipt = try client.produce(request)
        caches[request.topic] = nil
        return receipt
    }

    static func sortedTopics(
        _ topics: [KafkaTopicMetadata]
    ) -> [KafkaTopicMetadata] {
        topics.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        try requireConnection()
        guard database == "Kafka", topics[object.name] != nil else {
            throw WorkspaceSessionError.metadataUnavailable(object: object.name)
        }
        return WorkspaceDatabaseObjectDetails(
            columns: Self.detailsColumns,
            ddl: ""
        )
    }

    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] {
        try requireConnection()
        return []
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        try await fetchDataPage(
            for: object,
            in: database,
            offset: offset,
            limit: limit,
            sort: sort,
            filter: .empty,
            onBatch: onBatch
        )
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        filter: WorkspaceDatabaseDataFilter,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        try requireConnection()
        guard database == "Kafka", offset >= 0, limit > 0, filter.isValid else {
            throw filter.isValid
                ? WorkspaceSessionError.invalidPageRequest
                : WorkspaceSessionError.invalidDataFilter
        }
        guard offset <= Int.max - limit else {
            throw WorkspaceSessionError.invalidPageRequest
        }
        try await ensureMessages(
            for: object.name,
            atLeast: offset + limit,
            sort: sort,
            filter: filter,
            readUntilExhausted: sort != .none
        )
        let cache = caches[object.name] ?? TopicCache()
        let visible = Self.filteredMessages(
            cache.messages,
            using: sort,
            filter: filter
        )
        let page = Array(visible.dropFirst(offset).prefix(limit))
        if !page.isEmpty {
            await onBatch(
                WorkspaceDatabaseDataBatch(
                    columns: Self.dataColumns,
                    rows: page.enumerated().map { index, message in
                        WorkspaceDatabaseDataRow(
                            id: offset + index,
                            values: Self.row(message).values
                        )
                    }
                )
            )
        }
        return WorkspaceDatabaseDataFetchResult(
            columns: Self.dataColumns,
            hasNextPage: visible.count > offset + page.count
                || Self.hasUnexhaustedPartitions(
                    cache,
                    metadata: topics[object.name]
                )
        )
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        try await fetchDataCount(
            for: object,
            in: database,
            filter: .empty
        )
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String,
        filter: WorkspaceDatabaseDataFilter
    ) async throws -> Int {
        try requireConnection()
        guard database == "Kafka", filter.isValid else {
            throw filter.isValid
                ? WorkspaceSessionError.invalidPageRequest
                : WorkspaceSessionError.invalidDataFilter
        }
        // A count is a browsing aid; cap the read so a retained topic cannot
        // block the UI indefinitely.
        try await ensureMessages(
            for: object.name,
            atLeast: Self.maximumCountMessages,
            filter: filter,
            readUntilExhausted: false
        )
        let cache = caches[object.name] ?? TopicCache()
        return Self.filteredMessages(
            cache.messages,
            using: .none,
            filter: filter
        ).count
    }

    func close() async {
        client?.close()
        client = nil
        connected = false
        topics.removeAll()
        brokers.removeAll()
        caches.removeAll()
        readRequests.removeAll()
        completedScans.removeAll()
        scanIDs.removeAll()
    }

    private func refreshMetadata() async throws {
        guard let client else { throw WorkspaceSessionError.notConnected }
        let response = try client.metadata()
        brokers = response.brokers
        topics = Dictionary(
            uniqueKeysWithValues: response.topics.map { ($0.name, $0) }
        )
        caches = caches.filter { topics[$0.key] != nil }
    }

    private func ensureMessages(
        for topicName: String,
        atLeast target: Int,
        sort: WorkspaceDatabaseDataSort = .none,
        filter: WorkspaceDatabaseDataFilter = .empty,
        readUntilExhausted: Bool = false
    ) async throws {
        guard target > 0 else { return }
        if topics[topicName] == nil {
            try await refreshMetadata()
            guard topics[topicName] != nil else {
                throw WorkspaceSessionError.metadataUnavailable(object: topicName)
            }
        }
        var cycles = 0
        while true {
            try Task.checkCancellation()
            let cache = caches[topicName] ?? TopicCache()
            let hasEnoughRows = Self.hasEnoughRows(
                cache.messages,
                target: target,
                sort: sort,
                filter: filter
            )
            let hasUnexhaustedPartitions = Self.hasUnexhaustedPartitions(
                cache,
                metadata: topics[topicName]
            )
            guard Self.shouldFetchMore(
                cycles: cycles,
                hasEnoughRows: hasEnoughRows,
                hasUnexhaustedPartitions: hasUnexhaustedPartitions,
                readUntilExhausted: readUntilExhausted
            ) else {
                break
            }
            cycles += 1
            let previousMessageCount = cache.messages.count
            let previousExhausted = cache.exhausted
            let previousNextOffsets = cache.nextOffsets
            try await fetchMore(topicName: topicName)

            let updatedCache = caches[topicName] ?? TopicCache()
            guard updatedCache.messages.count != previousMessageCount
                    || updatedCache.exhausted != previousExhausted
                    || updatedCache.nextOffsets != previousNextOffsets
            else { break }
        }
    }

    static func fetchCycleLimit(readUntilExhausted: Bool) -> Int {
        readUntilExhausted
            ? maximumSortedFetchCycles
            : maximumFetchCycles
    }

    static func shouldFetchMore(
        cycles: Int,
        hasEnoughRows: Bool,
        hasUnexhaustedPartitions: Bool,
        readUntilExhausted: Bool
    ) -> Bool {
        guard hasUnexhaustedPartitions,
              cycles < fetchCycleLimit(readUntilExhausted: readUntilExhausted)
        else { return false }
        return readUntilExhausted || !hasEnoughRows
    }

    static func shouldExhaustEmptyFetch(
        highWatermark: Int64,
        startOffset: Int64
    ) -> Bool {
        highWatermark <= startOffset
    }

    private static func hasUnexhaustedPartitions(
        _ cache: TopicCache,
        metadata: KafkaTopicMetadata?
    ) -> Bool {
        guard let metadata else { return false }
        return metadata.partitions.contains {
            !cache.exhausted.contains($0.partition)
        }
    }

    private func fetchMore(topicName: String) async throws {
        guard let metadata = topics[topicName], let client else {
            throw WorkspaceSessionError.notConnected
        }
        var cache = caches[topicName] ?? TopicCache()
        let active = metadata.partitions.filter {
            !cache.exhausted.contains($0.partition)
        }
        guard !active.isEmpty else {
            caches[topicName] = cache
            return
        }

        let requestedOffsets: [Int32: Int64] = Dictionary(uniqueKeysWithValues: active.compactMap { partition in
            guard !cache.exhausted.contains(partition.partition) else { return nil }
            return (partition.partition, cache.nextOffsets[partition.partition] ?? 0)
        })
        let response = try client.fetch(topic: topicName, offsets: requestedOffsets)
        try Task.checkCancellation()
        let uniqueRecords = response.messages.filter { message in
            !cache.messages.contains {
                $0.partition == message.partition && $0.offset == message.offset
            }
        }
        cache.messages.append(contentsOf: uniqueRecords)
        for (partition, nextOffset) in response.nextOffsets {
            cache.nextOffsets[partition] = nextOffset
        }
        cache.exhausted.formUnion(response.exhausted)
        caches[topicName] = cache
    }

    private func requireConnection() throws {
        guard connected, let client, client.isConnected() else {
            self.client?.close()
            self.client = nil
            connected = false
            topics.removeAll()
            brokers.removeAll()
            caches.removeAll()
            throw WorkspaceSessionError.notConnected
        }
    }

    private func databaseNameIsValid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == name, !trimmed.isEmpty, trimmed.utf8.count <= 249 else {
            return false
        }
        return trimmed.allSatisfy { character in
            character.isLetter || character.isNumber || character == "."
                || character == "_" || character == "-"
        }
    }

    private static func sortedMessages(
        _ messages: [KafkaMessage],
        using sort: WorkspaceDatabaseDataSort
    ) -> [KafkaMessage] {
        messages.sorted { lhs, rhs in
            let result: ComparisonResult
            let columnName: String? = switch sort {
            case .none: nil
            case .ascending(let name), .descending(let name): name
            }
            switch columnName {
            case "partition":
                result = lhs.partition == rhs.partition
                    ? lhs.offset.compare(to: rhs.offset)
                    : lhs.partition.compare(to: rhs.partition)
            case "offset":
                result = lhs.offset == rhs.offset
                    ? lhs.partition.compare(to: rhs.partition)
                    : lhs.offset.compare(to: rhs.offset)
            case "timestamp":
                result = (lhs.timestamp ?? -1) == (rhs.timestamp ?? -1)
                    ? comparePosition(lhs, rhs)
                    : (lhs.timestamp ?? -1).compare(to: rhs.timestamp ?? -1)
            case "key":
                result = compareOptionalStrings(
                    displayText(lhs.key),
                    displayText(rhs.key),
                    tieBreaking: { comparePosition(lhs, rhs) }
                )
            case "headers":
                result = compareStrings(
                    headersText(lhs.headers),
                    headersText(rhs.headers),
                    tieBreaking: { comparePosition(lhs, rhs) }
                )
            case "value":
                result = compareOptionalStrings(
                    displayText(lhs.value),
                    displayText(rhs.value),
                    tieBreaking: { comparePosition(lhs, rhs) }
                )
            default:
                result = lhs.partition == rhs.partition
                    ? lhs.offset.compare(to: rhs.offset)
                    : lhs.partition.compare(to: rhs.partition)
            }
            switch sort {
            case .descending: return result == .orderedDescending
            case .ascending, .none: return result == .orderedAscending
            }
        }
    }

    private static func comparePosition(
        _ lhs: KafkaMessage,
        _ rhs: KafkaMessage
    ) -> ComparisonResult {
        lhs.partition == rhs.partition
            ? lhs.offset.compare(to: rhs.offset)
            : lhs.partition.compare(to: rhs.partition)
    }

    private static func compareOptionalStrings(
        _ lhs: String?,
        _ rhs: String?,
        tieBreaking: () -> ComparisonResult
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return tieBreaking()
        case (nil, _):
            return .orderedAscending
        case (_, nil):
            return .orderedDescending
        case let (lhs?, rhs?):
            return compareStrings(lhs, rhs, tieBreaking: tieBreaking)
        }
    }

    private static func compareStrings(
        _ lhs: String,
        _ rhs: String,
        tieBreaking: () -> ComparisonResult
    ) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return tieBreaking()
    }

    private static func displayText(_ value: Data?) -> String? {
        guard let value else { return nil }
        if let text = String(data: value, encoding: .utf8) {
            return text
        }
        return "base64:" + value.base64EncodedString()
    }

    /// Returns messages in display order after applying the workspace filter.
    /// Keeping this pure lets pagination and count paths share exactly the
    /// same filtering semantics.
    static func filteredMessages(
        _ messages: [KafkaMessage],
        using sort: WorkspaceDatabaseDataSort,
        filter: WorkspaceDatabaseDataFilter
    ) -> [KafkaMessage] {
        sortedMessages(messages, using: sort).filter { message in
            matches(row(message), columns: dataColumns, filter: filter)
        }
    }

    static func hasEnoughRows(
        _ messages: [KafkaMessage],
        target: Int,
        sort: WorkspaceDatabaseDataSort,
        filter: WorkspaceDatabaseDataFilter
    ) -> Bool {
        guard target > 0 else { return true }
        if filter.isActive {
            return filteredMessages(messages, using: sort, filter: filter).count >= target
        }
        return messages.count >= target
    }

    private static let dataColumns: [WorkspaceDatabaseDataColumn] = [
        WorkspaceDatabaseDataColumn(id: 0, name: "partition", type: "INT"),
        WorkspaceDatabaseDataColumn(id: 1, name: "offset", type: "BIGINT"),
        WorkspaceDatabaseDataColumn(id: 2, name: "timestamp", type: "BIGINT"),
        WorkspaceDatabaseDataColumn(id: 3, name: "key", type: "TEXT"),
        WorkspaceDatabaseDataColumn(id: 4, name: "headers", type: "TEXT"),
        WorkspaceDatabaseDataColumn(id: 5, name: "value", type: "TEXT"),
    ]

    private static let detailsColumns: [WorkspaceDatabaseColumn] = [
        WorkspaceDatabaseColumn(name: "partition", type: "INT", collation: nil, isNullable: false, key: "", defaultValue: nil, extra: "", comment: "Kafka partition"),
        WorkspaceDatabaseColumn(name: "offset", type: "BIGINT", collation: nil, isNullable: false, key: "", defaultValue: nil, extra: "", comment: "Kafka offset"),
        WorkspaceDatabaseColumn(name: "timestamp", type: "BIGINT", collation: nil, isNullable: true, key: "", defaultValue: nil, extra: "", comment: "Producer timestamp in milliseconds"),
        WorkspaceDatabaseColumn(name: "key", type: "TEXT", collation: nil, isNullable: true, key: "", defaultValue: nil, extra: "", comment: "Message key"),
        WorkspaceDatabaseColumn(name: "headers", type: "TEXT", collation: nil, isNullable: true, key: "", defaultValue: nil, extra: "", comment: "Message headers"),
        WorkspaceDatabaseColumn(name: "value", type: "TEXT", collation: nil, isNullable: true, key: "", defaultValue: nil, extra: "", comment: "Message value"),
    ]

    private static func row(_ message: KafkaMessage) -> WorkspaceDatabaseDataRow {
        WorkspaceDatabaseDataRow(
            id: Int(clamping: message.offset),
            values: [
                .text(String(message.partition)),
                .text(String(message.offset)),
                message.timestamp.map { .text(String($0)) } ?? .null,
                cell(message.key),
                .text(headersText(message.headers)),
                cell(message.value),
            ]
        )
    }

    private static func cell(_ value: Data?) -> WorkspaceDatabaseDataCell {
        guard let value else { return .null }
        if let text = String(data: value, encoding: .utf8) {
            return .text(text)
        }
        return .text("base64:" + value.base64EncodedString())
    }

    private static func headersText(_ headers: [KafkaHeader]) -> String {
        headers.map { header in
            let value: String
            if let bytes = header.value {
                value = String(data: bytes, encoding: .utf8)
                    ?? "base64:" + bytes.base64EncodedString()
            } else {
                value = "NULL"
            }
            return "\(header.key)=\(value)"
        }.joined(separator: ", ")
    }

    private static func matches(
        _ row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceDatabaseDataColumn],
        filter: WorkspaceDatabaseDataFilter
    ) -> Bool {
        let conditions = filter.effectiveConditions
        guard !conditions.isEmpty else { return true }
        let results = conditions.map { condition -> Bool in
            guard let index = columns.firstIndex(where: {
                $0.name.caseInsensitiveCompare(condition.columnName) == .orderedSame
            }) else { return false }
            let cell = row.value(at: index)
            let isNull = if case .null = cell { true } else { false }
            let text = Self.cellText(cell)
            switch condition.operation {
            case .isNull: return isNull
            case .exists: return !isNull
            case .isNotNull: return !isNull
            case .equal, .term: return text == condition.value
            case .notEqual: return text != condition.value
            case .contains, .match: return text.localizedCaseInsensitiveContains(condition.value)
            case .startsWith: return text.lowercased().hasPrefix(condition.value.lowercased())
            case .endsWith: return text.lowercased().hasSuffix(condition.value.lowercased())
            case .terms:
                return condition.value.split(separator: ",").map(String.init).contains(text)
            case .between:
                guard let number = Double(text),
                      let lower = Double(condition.value),
                      let upper = Double(condition.secondValue)
                else { return false }
                return number >= lower && number <= upper
            case .lessThan, .rangeLessThan:
                return numeric(text, condition.value) { $0 < $1 }
            case .lessThanOrEqual, .rangeLessThanOrEqual:
                return numeric(text, condition.value) { $0 <= $1 }
            case .greaterThan, .rangeGreaterThan:
                return numeric(text, condition.value) { $0 > $1 }
            case .greaterThanOrEqual, .rangeGreaterThanOrEqual:
                return numeric(text, condition.value) { $0 >= $1 }
            case .matchPhrase, .wildcard:
                return text.localizedCaseInsensitiveContains(condition.value)
            }
        }
        return filter.logic == .matchAll ? results.allSatisfy { $0 } : results.contains { $0 }
    }

    private static func numeric(
        _ lhs: String,
        _ rhs: String,
        _ compare: (Double, Double) -> Bool
    ) -> Bool {
        guard let lhs = Double(lhs), let rhs = Double(rhs) else { return false }
        return compare(lhs, rhs)
    }

    private static func cellText(_ cell: WorkspaceDatabaseDataCell) -> String {
        switch cell {
        case .null:
            return ""
        case let .text(value):
            return value
        case let .binary(byteCount, preview):
            return "<BINARY \(byteCount) bytes>" + preview.map(String.init).joined()
        }
    }
}

private extension Int64 {
    func compare(to other: Int64) -> ComparisonResult {
        if self < other { return .orderedAscending }
        if self > other { return .orderedDescending }
        return .orderedSame
    }
}

private extension Int32 {
    func compare(to other: Int32) -> ComparisonResult {
        if self < other { return .orderedAscending }
        if self > other { return .orderedDescending }
        return .orderedSame
    }
}
