import Foundation
import QueryCraftFeature

struct KafkaEncoder: Sendable {
    private(set) var data = Data()

    mutating func append(_ value: Data) {
        data.append(value)
    }

    mutating func int8(_ value: Int8) {
        data.append(UInt8(bitPattern: value))
    }

    mutating func int16(_ value: Int16) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    mutating func int32(_ value: Int32) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    mutating func int64(_ value: Int64) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        int16(Int16(clamping: bytes.count))
        data.append(bytes)
    }

    mutating func nullableString(_ value: String?) {
        guard let value else {
            int16(-1)
            return
        }
        string(value)
    }

    mutating func bytes(_ value: Data?) {
        guard let value else {
            int32(-1)
            return
        }
        int32(Int32(clamping: value.count))
        data.append(value)
    }

    mutating func arrayCount(_ count: Int) {
        int32(Int32(clamping: count))
    }
}

enum KafkaRequestFrame {
    static func make(
        apiKey: Int16,
        version: Int16,
        correlationID: Int32,
        clientID: String,
        body: Data
    ) -> Data {
        var request = KafkaEncoder()
        request.int16(apiKey)
        request.int16(version)
        request.int32(correlationID)
        request.string(clientID)
        request.append(body)
        var frame = KafkaEncoder()
        frame.int32(Int32(clamping: request.data.count))
        frame.append(request.data)
        return frame.data
    }
}

enum KafkaMetadataRequestEncoder {
    static let version: Int16 = 1

    static func encodeAllTopics() -> Data {
        var body = KafkaEncoder()
        // Metadata v1 uses a nullable topic array; null asks for every topic.
        body.int32(-1)
        return body.data
    }
}

struct KafkaDecoder: Sendable {
    let data: Data
    private(set) var offset = 0

    init(data: Data) {
        self.data = data
    }

    var remainingCount: Int { data.count - offset }

    mutating func int8() throws -> Int8 {
        let value = try readByte()
        return Int8(bitPattern: value)
    }

    mutating func int16() throws -> Int16 {
        let bytes = try readBytes(count: 2)
        return bytes.withUnsafeBytes {
            Int16(bigEndian: $0.loadUnaligned(as: Int16.self))
        }
    }

    mutating func int32() throws -> Int32 {
        let bytes = try readBytes(count: 4)
        return bytes.withUnsafeBytes {
            Int32(bigEndian: $0.loadUnaligned(as: Int32.self))
        }
    }

    mutating func int64() throws -> Int64 {
        let bytes = try readBytes(count: 8)
        return bytes.withUnsafeBytes {
            Int64(bigEndian: $0.loadUnaligned(as: Int64.self))
        }
    }

    mutating func string() throws -> String {
        let length = try int16()
        guard length >= 0 else { throw KafkaError.invalidResponse }
        let bytes = try readBytes(count: Int(length))
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw KafkaError.invalidResponse
        }
        return value
    }

    mutating func nullableString() throws -> String? {
        let length = try int16()
        guard length >= -1 else { throw KafkaError.invalidResponse }
        guard length >= 0 else { return nil }
        let bytes = try readBytes(count: Int(length))
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw KafkaError.invalidResponse
        }
        return value
    }

    mutating func bytes() throws -> Data? {
        let length = try int32()
        guard length >= -1 else { throw KafkaError.invalidResponse }
        guard length >= 0 else { return nil }
        return try readBytes(count: Int(length))
    }

    mutating func arrayCount() throws -> Int {
        let count = try int32()
        guard count >= 0,
              Int64(count) <= Int64(remainingCount)
        else { throw KafkaError.invalidResponse }
        return Int(count)
    }

    mutating func nullableArrayCount() throws -> Int? {
        let count = try int32()
        guard count >= -1,
              count < 0 || Int64(count) <= Int64(remainingCount)
        else { throw KafkaError.invalidResponse }
        return count < 0 ? nil : Int(count)
    }

    mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= data.count else {
            throw KafkaError.invalidResponse
        }
        offset = newOffset
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw KafkaError.invalidResponse
        }
        let value = data.subdata(in: offset..<(offset + count))
        offset += count
        return value
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw KafkaError.invalidResponse }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func unsignedVarInt() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift <= 63 {
            let byte = try readByte()
            guard shift < 63 || byte & 0x7e == 0 else {
                throw KafkaError.invalidResponse
            }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            guard shift < 63 else { throw KafkaError.invalidResponse }
            shift += 7
        }
        throw KafkaError.invalidResponse
    }

    mutating func varInt() throws -> Int64 {
        let encoded = try unsignedVarInt()
        // Kafka uses zig-zag encoding for signed compact values.  The
        // subtraction is wrapping so the odd values become an all-ones mask.
        let signMask = UInt64(0) &- (encoded & 1)
        return Int64(bitPattern: (encoded >> 1) ^ signMask)
    }
}

struct KafkaBrokerMetadata: Equatable, Sendable {
    let nodeID: Int32
    let host: String
    let port: Int32

    var address: KafkaBrokerAddress {
        KafkaBrokerAddress(host: host, port: Int(port))
    }
}

struct KafkaPartitionMetadata: Equatable, Sendable {
    let partition: Int32
    let leader: Int32
}

struct KafkaTopicMetadata: Equatable, Sendable {
    let name: String
    let partitions: [KafkaPartitionMetadata]
}

struct KafkaMetadataResponse: Equatable, Sendable {
    let correlationID: Int32
    let throttleTimeMilliseconds: Int32?
    let brokers: [KafkaBrokerMetadata]
    let clusterID: String?
    let controllerID: Int32?
    let topics: [KafkaTopicMetadata]
}

struct KafkaHeader: Equatable, Sendable {
    let key: String
    let value: Data?
}

struct KafkaMessage: Equatable, Sendable {
    let partition: Int32
    let offset: Int64
    let timestamp: Int64?
    let key: Data?
    let value: Data?
    let headers: [KafkaHeader]
}

struct KafkaSASLHandshakeResponse: Equatable, Sendable {
    let correlationID: Int32
    let errorCode: Int16
    let mechanisms: [String]
}

struct KafkaSASLAuthenticateResponse: Equatable, Sendable {
    let correlationID: Int32
    let errorCode: Int16
    let errorMessage: String?
    let authBytes: Data?
}

enum KafkaSASLResponseDecoder {
    static func decodeHandshake(_ data: Data) throws -> KafkaSASLHandshakeResponse {
        var decoder = KafkaDecoder(data: data)
        let correlationID = try decoder.int32()
        let errorCode = try decoder.int16()
        let count = try decoder.arrayCount()
        var mechanisms: [String] = []
        mechanisms.reserveCapacity(count)
        for _ in 0..<count {
            mechanisms.append(try decoder.string())
        }
        guard decoder.remainingCount == 0 else {
            throw KafkaError.invalidResponse
        }
        return KafkaSASLHandshakeResponse(
            correlationID: correlationID,
            errorCode: errorCode,
            mechanisms: mechanisms
        )
    }

    static func decodeAuthenticate(_ data: Data) throws -> KafkaSASLAuthenticateResponse {
        var decoder = KafkaDecoder(data: data)
        let correlationID = try decoder.int32()
        let errorCode = try decoder.int16()
        let errorMessage = try decoder.nullableString()
        let authBytes = try decoder.bytes()
        guard decoder.remainingCount == 0 else {
            throw KafkaError.invalidResponse
        }
        return KafkaSASLAuthenticateResponse(
            correlationID: correlationID,
            errorCode: errorCode,
            errorMessage: errorMessage,
            authBytes: authBytes
        )
    }
}

enum KafkaMetadataDecoder {
    /// Decodes a version 0 Metadata response.  Newer response versions can
    /// be decoded by passing `includesThrottleTime` and
    /// `includesClusterMetadata` as appropriate for the request version.
    static func decode(_ data: Data) throws -> [KafkaTopicMetadata] {
        try decodeResponse(data).topics
    }

    static func decodeResponse(
        _ data: Data,
        includesThrottleTime: Bool = false,
        includesClusterMetadata: Bool = false,
        includesBrokerRack: Bool = false,
        includesControllerMetadata: Bool = false,
        includesInternalTopicFlag: Bool = false
    ) throws -> KafkaMetadataResponse {
        var decoder = KafkaDecoder(data: data)
        let correlationID = try decoder.int32()
        let throttleTimeMilliseconds: Int32? = if includesThrottleTime {
            try decoder.int32()
        } else {
            nil
        }
        let brokerCount = try decoder.arrayCount()
        var brokers: [KafkaBrokerMetadata] = []
        brokers.reserveCapacity(brokerCount)
        for _ in 0..<brokerCount {
            let nodeID = try decoder.int32()
            let host = try decoder.string()
            let port = try decoder.int32()
            guard nodeID >= 0,
                  !host.isEmpty,
                  (1...65_535).contains(port)
            else {
                throw KafkaError.invalidResponse
            }
            guard !brokers.contains(where: { $0.nodeID == nodeID }) else {
                throw KafkaError.invalidResponse
            }
            if includesBrokerRack {
                _ = try decoder.nullableString()
            }
            brokers.append(KafkaBrokerMetadata(
                nodeID: nodeID,
                host: host,
                port: port
            ))
        }

        let clusterID: String?
        let controllerID: Int32?
        if includesClusterMetadata {
            clusterID = try decoder.nullableString()
            controllerID = try decoder.int32()
        } else if includesControllerMetadata {
            clusterID = nil
            controllerID = try decoder.int32()
        } else {
            clusterID = nil
            controllerID = nil
        }

        let topicCount = try decoder.arrayCount()
        var topics: [KafkaTopicMetadata] = []
        topics.reserveCapacity(topicCount)
        for _ in 0..<topicCount {
            let errorCode = try decoder.int16()
            let name = try decoder.string()
            guard !name.isEmpty,
                  !topics.contains(where: { $0.name == name })
            else {
                throw KafkaError.invalidResponse
            }
            if includesInternalTopicFlag {
                let isInternal = try decoder.int8()
                guard isInternal == 0 || isInternal == 1 else {
                    throw KafkaError.invalidResponse
                }
            }
            let partitionCount = try decoder.arrayCount()
            var partitions: [KafkaPartitionMetadata] = []
            partitions.reserveCapacity(partitionCount)
            for _ in 0..<partitionCount {
                let partitionError = try decoder.int16()
                let partition = try decoder.int32()
                let leader = try decoder.int32()
                guard partition >= 0,
                      !partitions.contains(where: { $0.partition == partition })
                else {
                    throw KafkaError.invalidResponse
                }
                let replicaCount = try decoder.arrayCount()
                for _ in 0..<replicaCount { _ = try decoder.int32() }
                let isrCount = try decoder.arrayCount()
                for _ in 0..<isrCount { _ = try decoder.int32() }
                guard partitionError == 0 else {
                    throw KafkaError.protocolError(code: partitionError, message: "topic \(name)")
                }
                partitions.append(KafkaPartitionMetadata(partition: partition, leader: leader))
            }
            guard errorCode == 0 else {
                throw KafkaError.protocolError(code: errorCode, message: "topic \(name)")
            }
            topics.append(KafkaTopicMetadata(name: name, partitions: partitions))
        }
        guard decoder.remainingCount == 0 else {
            throw KafkaError.invalidResponse
        }
        return KafkaMetadataResponse(
            correlationID: correlationID,
            throttleTimeMilliseconds: throttleTimeMilliseconds,
            brokers: brokers,
            clusterID: clusterID,
            controllerID: controllerID,
            topics: topics
        )
    }
}

struct KafkaAbortedTransaction: Equatable, Sendable {
    let producerID: Int64
    let firstOffset: Int64
}

struct KafkaFetchPartitionResponse: Equatable, Sendable {
    let partition: Int32
    let errorCode: Int16
    let highWatermark: Int64
    let records: Data?
    let lastStableOffset: Int64?
    let logStartOffset: Int64?
    let abortedTransactions: [KafkaAbortedTransaction]?
    let preferredReadReplica: Int32?

    init(
        partition: Int32,
        errorCode: Int16,
        highWatermark: Int64,
        records: Data?,
        lastStableOffset: Int64? = nil,
        logStartOffset: Int64? = nil,
        abortedTransactions: [KafkaAbortedTransaction]? = nil,
        preferredReadReplica: Int32? = nil
    ) {
        self.partition = partition
        self.errorCode = errorCode
        self.highWatermark = highWatermark
        self.records = records
        self.lastStableOffset = lastStableOffset
        self.logStartOffset = logStartOffset
        self.abortedTransactions = abortedTransactions
        self.preferredReadReplica = preferredReadReplica
    }
}

struct KafkaFetchTopicResponse: Equatable, Sendable {
    let name: String
    let partitions: [KafkaFetchPartitionResponse]
}

struct KafkaFetchResponse: Equatable, Sendable {
    let correlationID: Int32
    let throttleTimeMilliseconds: Int32?
    let errorCode: Int16?
    let sessionID: Int32?
    let topics: [KafkaFetchTopicResponse]

    init(
        correlationID: Int32,
        throttleTimeMilliseconds: Int32? = nil,
        errorCode: Int16? = nil,
        sessionID: Int32? = nil,
        topics: [KafkaFetchTopicResponse]
    ) {
        self.correlationID = correlationID
        self.throttleTimeMilliseconds = throttleTimeMilliseconds
        self.errorCode = errorCode
        self.sessionID = sessionID
        self.topics = topics
    }
}

enum KafkaFetchResponseDecoder {
    /// Decodes Fetch responses. Version 0 is the legacy MessageSet response;
    /// version 1-3 add throttle time, version 4 adds transaction metadata,
    /// version 5 adds the log-start offset, version 7 adds fetch-session
    /// error/session fields, and version 11 adds the preferred read replica.
    static func decode(
        _ data: Data,
        version: Int16 = 0
    ) throws -> KafkaFetchResponse {
        var decoder = KafkaDecoder(data: data)
        let correlationID = try decoder.int32()
        let throttleTimeMilliseconds: Int32? = version >= 1
            ? try decoder.int32()
            : nil
        let errorCode: Int16? = version >= 7
            ? try decoder.int16()
            : nil
        let sessionID: Int32? = version >= 7
            ? try decoder.int32()
            : nil
        let topicCount = try decoder.arrayCount()
        var topics: [KafkaFetchTopicResponse] = []
        topics.reserveCapacity(topicCount)
        for _ in 0..<topicCount {
            let name = try decoder.string()
            guard !name.isEmpty,
                  !topics.contains(where: { $0.name == name })
            else {
                throw KafkaError.invalidResponse
            }
            let partitionCount = try decoder.arrayCount()
            var partitions: [KafkaFetchPartitionResponse] = []
            partitions.reserveCapacity(partitionCount)
            for _ in 0..<partitionCount {
                let partition = try decoder.int32()
                guard partition >= 0,
                      !partitions.contains(where: { $0.partition == partition })
                else {
                    throw KafkaError.invalidResponse
                }
                let partitionError = try decoder.int16()
                let highWatermark = try decoder.int64()
                if version < 4 {
                    partitions.append(KafkaFetchPartitionResponse(
                        partition: partition,
                        errorCode: partitionError,
                        highWatermark: highWatermark,
                        records: try decoder.bytes()
                    ))
                    continue
                }
                let lastStableOffset = try decoder.int64()
                let logStartOffset: Int64? = version >= 5
                    ? try decoder.int64()
                    : nil
                let abortedTransactions = try decoder.nullableArrayCount().map {
                    count -> [KafkaAbortedTransaction] in
                    var transactions: [KafkaAbortedTransaction] = []
                    transactions.reserveCapacity(count)
                    for _ in 0..<count {
                        transactions.append(KafkaAbortedTransaction(
                            producerID: try decoder.int64(),
                            firstOffset: try decoder.int64()
                        ))
                    }
                    return transactions
                }
                let preferredReadReplica: Int32? = version >= 11
                    ? try decoder.int32()
                    : nil
                partitions.append(KafkaFetchPartitionResponse(
                    partition: partition,
                    errorCode: partitionError,
                    highWatermark: highWatermark,
                    records: try decoder.bytes(),
                    lastStableOffset: lastStableOffset,
                    logStartOffset: logStartOffset,
                    abortedTransactions: abortedTransactions,
                    preferredReadReplica: preferredReadReplica
                ))
            }
            topics.append(KafkaFetchTopicResponse(
                name: name,
                partitions: partitions
            ))
        }
        guard decoder.remainingCount == 0 else {
            throw KafkaError.invalidResponse
        }
        return KafkaFetchResponse(
            correlationID: correlationID,
            throttleTimeMilliseconds: throttleTimeMilliseconds,
            errorCode: errorCode,
            sessionID: sessionID,
            topics: topics
        )
    }

    static func decode(
        _ data: Data,
        includesThrottleTime: Bool
    ) throws -> KafkaFetchResponse {
        try decode(data, version: includesThrottleTime ? 1 : 0)
    }
}

// Keep the shorter name available to the session implementation and tests.
enum KafkaFetchDecoder {
    static func decode(
        _ data: Data,
        version: Int16 = 0
    ) throws -> KafkaFetchResponse {
        try KafkaFetchResponseDecoder.decode(data, version: version)
    }
}

struct KafkaFetchV4RequestPartition: Equatable, Sendable {
    let partition: Int32
    let fetchOffset: Int64
    let logStartOffset: Int64
    let partitionMaximumBytes: Int32
}

struct KafkaFetchV4RequestTopic: Equatable, Sendable {
    let name: String
    let partitions: [KafkaFetchV4RequestPartition]
}

struct KafkaForgottenTopic: Equatable, Sendable {
    let name: String
    let partitions: [Int32]
}

enum KafkaFetchRequestEncoder {
    static func encodeV4(
        replicaID: Int32 = -1,
        maximumWaitMilliseconds: Int32,
        minimumBytes: Int32,
        maximumBytes: Int32,
        isolationLevel: Int8 = 0,
        topics: [KafkaFetchV4RequestTopic]
    ) -> Data {
        var encoder = KafkaEncoder()
        encoder.int32(replicaID)
        encoder.int32(maximumWaitMilliseconds)
        encoder.int32(minimumBytes)
        encoder.int32(maximumBytes)
        encoder.int8(isolationLevel)
        encoder.arrayCount(topics.count)
        for topic in topics {
            encoder.string(topic.name)
            encoder.arrayCount(topic.partitions.count)
            for partition in topic.partitions {
                encoder.int32(partition.partition)
                encoder.int64(partition.fetchOffset)
                encoder.int64(partition.logStartOffset)
                encoder.int32(partition.partitionMaximumBytes)
            }
        }
        return encoder.data
    }

    /// Encodes the incremental-fetch-session request introduced after v4.
    static func encodeV7(
        replicaID: Int32 = -1,
        maximumWaitMilliseconds: Int32,
        minimumBytes: Int32,
        maximumBytes: Int32,
        isolationLevel: Int8 = 0,
        sessionID: Int32 = 0,
        sessionEpoch: Int32 = -1,
        topics: [KafkaFetchV4RequestTopic],
        forgottenTopics: [KafkaForgottenTopic] = [],
        rackID: String = ""
    ) -> Data {
        var encoder = KafkaEncoder()
        encoder.int32(replicaID)
        encoder.int32(maximumWaitMilliseconds)
        encoder.int32(minimumBytes)
        encoder.int32(maximumBytes)
        encoder.int8(isolationLevel)
        encoder.int32(sessionID)
        encoder.int32(sessionEpoch)
        encoder.arrayCount(topics.count)
        for topic in topics {
            encoder.string(topic.name)
            encoder.arrayCount(topic.partitions.count)
            for partition in topic.partitions {
                encoder.int32(partition.partition)
                encoder.int64(partition.fetchOffset)
                encoder.int64(partition.logStartOffset)
                encoder.int32(partition.partitionMaximumBytes)
            }
        }
        encoder.arrayCount(forgottenTopics.count)
        for topic in forgottenTopics {
            encoder.string(topic.name)
            encoder.arrayCount(topic.partitions.count)
            for partition in topic.partitions {
                encoder.int32(partition)
            }
        }
        encoder.string(rackID)
        return encoder.data
    }
}

struct KafkaListOffsetsRequestPartition: Equatable, Sendable {
    let partition: Int32
    let timestamp: Int64
}

struct KafkaListOffsetsRequestTopic: Equatable, Sendable {
    let name: String
    let partitions: [KafkaListOffsetsRequestPartition]
}

enum KafkaListOffsetsRequestEncoder {
    /// Encodes the version 1 ListOffsets request body. A timestamp of -1
    /// asks for the latest offset and -2 asks for the earliest offset.
    static func encodeV1(
        replicaID: Int32 = -1,
        topics: [KafkaListOffsetsRequestTopic]
    ) -> Data {
        var encoder = KafkaEncoder()
        encoder.int32(replicaID)
        encoder.arrayCount(topics.count)
        for topic in topics {
            encoder.string(topic.name)
            encoder.arrayCount(topic.partitions.count)
            for partition in topic.partitions {
                encoder.int32(partition.partition)
                encoder.int64(partition.timestamp)
            }
        }
        return encoder.data
    }
}

struct KafkaListOffsetsPartitionResponse: Equatable, Sendable {
    let partition: Int32
    let errorCode: Int16
    let timestamp: Int64
    let offset: Int64
}

struct KafkaListOffsetsTopicResponse: Equatable, Sendable {
    let name: String
    let partitions: [KafkaListOffsetsPartitionResponse]
}

struct KafkaListOffsetsResponse: Equatable, Sendable {
    let correlationID: Int32
    let throttleTimeMilliseconds: Int32?
    let topics: [KafkaListOffsetsTopicResponse]
}

enum KafkaListOffsetsResponseDecoder {
    static func decodeV1(_ data: Data) throws -> KafkaListOffsetsResponse {
        var decoder = KafkaDecoder(data: data)
        let correlationID = try decoder.int32()
        let throttleTimeMilliseconds = try decoder.int32()
        let topicCount = try decoder.arrayCount()
        var topics: [KafkaListOffsetsTopicResponse] = []
        topics.reserveCapacity(topicCount)
        for _ in 0..<topicCount {
            let name = try decoder.string()
            guard !name.isEmpty,
                  !topics.contains(where: { $0.name == name })
            else {
                throw KafkaError.invalidResponse
            }
            let partitionCount = try decoder.arrayCount()
            var partitions: [KafkaListOffsetsPartitionResponse] = []
            partitions.reserveCapacity(partitionCount)
            for _ in 0..<partitionCount {
                let partition = try decoder.int32()
                guard partition >= 0,
                      !partitions.contains(where: { $0.partition == partition })
                else {
                    throw KafkaError.invalidResponse
                }
                let errorCode = try decoder.int16()
                let timestamp = try decoder.int64()
                let offset = try decoder.int64()
                guard offset >= -1 else { throw KafkaError.invalidResponse }
                partitions.append(KafkaListOffsetsPartitionResponse(
                    partition: partition,
                    errorCode: errorCode,
                    timestamp: timestamp,
                    offset: offset
                ))
            }
            topics.append(KafkaListOffsetsTopicResponse(
                name: name,
                partitions: partitions
            ))
        }
        guard decoder.remainingCount == 0 else {
            throw KafkaError.invalidResponse
        }
        return KafkaListOffsetsResponse(
            correlationID: correlationID,
            throttleTimeMilliseconds: throttleTimeMilliseconds,
            topics: topics
        )
    }
}

enum KafkaRecordBatchDecoder {
    struct DecodeResult: Equatable, Sendable {
        let messages: [KafkaMessage]
        /// The next offset after every batch in the response, including
        /// control batches that are intentionally omitted from `messages`.
        let nextOffset: Int64?
    }

    static func decode(_ data: Data, partition: Int32) throws -> [KafkaMessage] {
        try decodeWithProgress(data, partition: partition).messages
    }

    static func decodeWithProgress(
        _ data: Data,
        partition: Int32
    ) throws -> DecodeResult {
        guard !data.isEmpty else {
            return DecodeResult(messages: [], nextOffset: nil)
        }
        var decoder = KafkaDecoder(data: data)
        var messages: [KafkaMessage] = []
        var highestOffset: Int64?
        while decoder.remainingCount >= 12 {
            let entryStart = decoder.offset
            let baseOffset = try decoder.int64()
            guard baseOffset >= 0 else { throw KafkaError.invalidResponse }
            let batchLength = try decoder.int32()
            guard batchLength >= 0, Int(batchLength) <= decoder.remainingCount else {
                throw KafkaError.invalidResponse
            }
            let batchEnd = decoder.offset + Int(batchLength)
            guard batchEnd <= data.count else { throw KafkaError.invalidResponse }
            var headerDecoder = decoder
            _ = try headerDecoder.int32()
            let magic = try headerDecoder.int8()
            try decoder.seek(to: entryStart + 12)
            switch magic {
            case 0, 1:
                let message = try decodeLegacyMessage(
                    from: &decoder,
                    partition: partition,
                    offset: baseOffset,
                    magic: magic,
                    end: batchEnd
                )
                messages.append(message)
                highestOffset = max(highestOffset ?? message.offset, message.offset)
            case 2:
                let batch = try decodeRecordBatch(
                    from: &decoder,
                    partition: partition,
                    baseOffset: baseOffset,
                    end: batchEnd
                )
                messages.append(contentsOf: batch.messages)
                highestOffset = max(highestOffset ?? batch.highestOffset, batch.highestOffset)
            default:
                throw KafkaError.messageDecode(
                    "unsupported message batch version (magic)"
                )
            }
            try decoder.seek(to: batchEnd)
        }
        guard decoder.remainingCount == 0 else {
            throw KafkaError.invalidResponse
        }
        let nextOffset: Int64?
        if let highestOffset {
            let (value, didOverflow) = highestOffset.addingReportingOverflow(1)
            guard !didOverflow else { throw KafkaError.invalidResponse }
            nextOffset = value
        } else {
            nextOffset = nil
        }
        return DecodeResult(messages: messages, nextOffset: nextOffset)
    }

    private static func decodeLegacyMessage(
        from decoder: inout KafkaDecoder,
        partition: Int32,
        offset: Int64,
        magic: Int8,
        end: Int
    ) throws -> KafkaMessage {
        _ = try decoder.int32() // CRC
        let actualMagic = try decoder.int8()
        guard actualMagic == magic else { throw KafkaError.invalidResponse }
        let attributes = try decoder.int8()
        // MessageSet compression is encoded in the low two attribute bits.
        // The payload would contain a nested compressed MessageSet, which this
        // read-only driver cannot safely inspect without a codec dependency.
        guard UInt8(bitPattern: attributes) & 0x03 == 0 else {
            throw KafkaError.unsupportedCompression
        }
        let timestamp: Int64?
        if magic == 1 {
            let value = try decoder.int64()
            guard value >= -1 else { throw KafkaError.invalidResponse }
            timestamp = value >= 0 ? value : nil
        } else {
            timestamp = nil
        }
        let key = try decoder.bytes()
        let value = try decoder.bytes()
        // The message size is exact. Accepting unread bytes here would hide
        // a malformed MessageSet entry and let the outer decoder silently
        // discard data before advancing to the next offset.
        guard decoder.offset == end else { throw KafkaError.invalidResponse }
        return KafkaMessage(
            partition: partition,
            offset: offset,
            timestamp: timestamp,
            key: key,
            value: value,
            headers: []
        )
    }

    private static func decodeRecordBatch(
        from decoder: inout KafkaDecoder,
        partition: Int32,
        baseOffset: Int64,
        end: Int
    ) throws -> (messages: [KafkaMessage], highestOffset: Int64) {
        _ = try decoder.int32() // partition leader epoch
        _ = try decoder.int8() // magic
        _ = try decoder.int32() // CRC
        let attributes = try decoder.int16()
        guard attributes & 0x07 == 0 else {
            throw KafkaError.unsupportedCompression
        }
        let isControlBatch = attributes & 0x20 != 0
        let lastOffsetDelta = try decoder.int32()
        guard lastOffsetDelta >= 0 else { throw KafkaError.invalidResponse }
        let (highestOffset, offsetOverflow) = baseOffset.addingReportingOverflow(
            Int64(lastOffsetDelta)
        )
        guard !offsetOverflow else { throw KafkaError.invalidResponse }
        let firstTimestamp = try decoder.int64()
        let maxTimestamp = try decoder.int64()
        guard firstTimestamp >= -1,
              maxTimestamp >= -1,
              (firstTimestamp < 0) == (maxTimestamp < 0),
              firstTimestamp < 0 || maxTimestamp >= firstTimestamp
        else {
            throw KafkaError.invalidResponse
        }
        _ = try decoder.int64() // producer id
        _ = try decoder.int16() // producer epoch
        _ = try decoder.int32() // base sequence
        let recordCount = try decoder.int32()
        guard recordCount >= 0,
              Int64(recordCount) <= Int64(decoder.remainingCount)
        else { throw KafkaError.invalidResponse }

        var messages: [KafkaMessage] = []
        messages.reserveCapacity(Int(recordCount))
        var previousOffsetDelta: Int64?
        for _ in 0..<recordCount {
            let recordLength = try decoder.varInt()
            guard recordLength >= 0,
                  recordLength <= Int64(decoder.remainingCount) else {
                throw KafkaError.invalidResponse
            }
            let recordEnd = decoder.offset + Int(recordLength)
            // Record attributes is a fixed-width int8 in the v2 record
            // format. It is currently reserved and must not be decoded as a
            // zig-zag varint, otherwise a high-bit value would consume bytes
            // belonging to the timestamp delta and desynchronise the record.
            _ = try decoder.int8()
            let timestampDelta = try decoder.varInt()
            let offsetDelta = try decoder.varInt()
            // Timestamp deltas are signed varlongs. A producer may provide
            // timestamps that move backwards within a batch, so only the
            // offset delta is constrained to be non-negative.
            guard offsetDelta >= 0,
                  offsetDelta <= Int64(lastOffsetDelta),
                  previousOffsetDelta.map { offsetDelta > $0 } ?? true
            else { throw KafkaError.invalidResponse }
            previousOffsetDelta = offsetDelta
            let keyLength = try decoder.varInt()
            let key = try readNullableBytes(&decoder, length: keyLength)
            let valueLength = try decoder.varInt()
            let value = try readNullableBytes(&decoder, length: valueLength)
            let headerCount = try decoder.varInt()
            guard headerCount >= 0,
                  headerCount <= Int64(decoder.remainingCount)
            else { throw KafkaError.invalidResponse }
            var headers: [KafkaHeader] = []
            headers.reserveCapacity(Int(headerCount))
            for _ in 0..<Int(headerCount) {
                let headerKeyLength = try decoder.varInt()
                guard headerKeyLength >= 0,
                      headerKeyLength <= Int64(decoder.remainingCount)
                else { throw KafkaError.invalidResponse }
                let headerKeyData = try decoder.readBytes(count: Int(headerKeyLength))
                guard let headerKey = String(data: headerKeyData, encoding: .utf8) else {
                    throw KafkaError.invalidResponse
                }
                let headerValueLength = try decoder.varInt()
                let headerValue = try readNullableBytes(
                    &decoder,
                    length: headerValueLength
                )
                headers.append(KafkaHeader(key: headerKey, value: headerValue))
            }
            guard decoder.offset <= recordEnd else { throw KafkaError.invalidResponse }
            try decoder.seek(to: recordEnd)
            let (offset, didOverflow) = baseOffset.addingReportingOverflow(offsetDelta)
            guard !didOverflow else { throw KafkaError.invalidResponse }
            let timestamp: Int64?
            if firstTimestamp < 0 {
                timestamp = nil
            } else {
                let (value, timestampOverflow) = firstTimestamp
                    .addingReportingOverflow(timestampDelta)
                guard !timestampOverflow else { throw KafkaError.invalidResponse }
                timestamp = value
            }
            if !isControlBatch {
                messages.append(KafkaMessage(
                    partition: partition,
                    offset: offset,
                    timestamp: timestamp,
                    key: key,
                    value: value,
                    headers: headers
                ))
            }
        }
        guard recordCount == 0
                ? lastOffsetDelta == 0
                : previousOffsetDelta == Int64(lastOffsetDelta)
        else { throw KafkaError.invalidResponse }
        // A record batch has no padding between its record array and the
        // length-delimited batch boundary.
        guard decoder.offset == end else { throw KafkaError.invalidResponse }
        return (messages: messages, highestOffset: highestOffset)
    }

    private static func readNullableBytes(
        _ decoder: inout KafkaDecoder,
        length: Int64
    ) throws -> Data? {
        guard length >= -1, length <= Int64(decoder.remainingCount) else {
            throw KafkaError.invalidResponse
        }
        guard length >= 0 else { return nil }
        return try decoder.readBytes(count: Int(length))
    }
}
