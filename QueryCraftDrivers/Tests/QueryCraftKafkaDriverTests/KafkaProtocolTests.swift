import Foundation
import QueryCraftFeature
import Testing
@testable import QueryCraftKafkaDriver

@Suite("Kafka protocol")
struct KafkaProtocolTests {
    @Test("Parses bootstrap servers and SASL configuration")
    func connectionConfiguration() throws {
        let configuration = DatabaseConnectionConfiguration(
            databaseType: .kafka,
            databaseProduct: .kafka,
            host: "broker-a, broker-b:19093, [::1]:29093",
            port: 9092,
            authentication: .usernamePassword(
                username: "reader",
                password: "secret"
            ),
            database: nil,
            tlsMode: .required
        )

        let parsed = try KafkaConnectionConfiguration(configuration)
        #expect(parsed.bootstrapServers == [
            KafkaBrokerAddress(host: "broker-a", port: 9092),
            KafkaBrokerAddress(host: "broker-b", port: 19093),
            KafkaBrokerAddress(host: "::1", port: 29093),
        ])
        #expect(parsed.username == "reader")
        #expect(parsed.password == "secret")
        #expect(parsed.tlsMode == .required)

        #expect(throws: KafkaError.self) {
            _ = try KafkaConnectionConfiguration(
                DatabaseConnectionConfiguration(
                    databaseType: .kafka,
                    databaseProduct: .kafka,
                    host: "broker-a",
                    port: 9092,
                    authentication: .usernamePassword(
                        username: "reader\0",
                        password: "secret"
                    ),
                    database: nil,
                    tlsMode: .disabled
                )
            )
        }
    }

    @Test("Kafka request frame has a length prefix and correlation header")
    func requestFrame() throws {
        let frame = KafkaRequestFrame.make(
            apiKey: 3,
            version: 0,
            correlationID: 42,
            clientID: "test",
            body: Data([0xff, 0x00])
        )
        var decoder = KafkaDecoder(data: frame)
        let length = try decoder.int32()
        #expect(Int(length) == frame.count - 4)
        #expect(try decoder.int16() == 3)
        #expect(try decoder.int16() == 0)
        #expect(try decoder.int32() == 42)
        #expect(try decoder.string() == "test")
        #expect(try decoder.readBytes(count: 2) == Data([0xff, 0x00]))
    }

    @Test("Encodes Metadata v1 request for all topics")
    func metadataRequest() throws {
        #expect(KafkaMetadataRequestEncoder.version == 1)
        var decoder = KafkaDecoder(
            data: KafkaMetadataRequestEncoder.encodeAllTopics()
        )
        #expect(try decoder.int32() == -1)
        #expect(decoder.remainingCount == 0)
    }

    @Test("Decodes Metadata v0 brokers, leaders, and topics")
    func metadataResponse() throws {
        var data = KafkaEncoder()
        data.int32(7)
        data.arrayCount(1)
        data.int32(2)
        data.string("broker")
        data.int32(9092)
        data.arrayCount(1)
        data.int16(0)
        data.string("events")
        data.arrayCount(1)
        data.int16(0)
        data.int32(3)
        data.int32(2)
        data.arrayCount(1)
        data.int32(2)
        data.arrayCount(1)
        data.int32(2)

        let response = try KafkaMetadataDecoder.decodeResponse(data.data)
        #expect(response.correlationID == 7)
        #expect(response.brokers == [
            KafkaBrokerMetadata(nodeID: 2, host: "broker", port: 9092),
        ])
        #expect(response.topics == [
            KafkaTopicMetadata(
                name: "events",
                partitions: [KafkaPartitionMetadata(partition: 3, leader: 2)]
            ),
        ])
    }

    @Test("Decodes and validates SASL PLAIN response bodies")
    func saslResponses() throws {
        var handshake = KafkaEncoder()
        handshake.int32(4)
        handshake.int16(0)
        handshake.arrayCount(2)
        handshake.string("SCRAM-SHA-256")
        handshake.string("PLAIN")
        let handshakeResponse = try KafkaSASLResponseDecoder.decodeHandshake(handshake.data)
        #expect(handshakeResponse == KafkaSASLHandshakeResponse(
            correlationID: 4,
            errorCode: 0,
            mechanisms: ["SCRAM-SHA-256", "PLAIN"]
        ))

        var authenticate = KafkaEncoder()
        authenticate.int32(5)
        authenticate.int16(0)
        authenticate.nullableString(nil)
        authenticate.bytes(Data())
        let authenticateResponse = try KafkaSASLResponseDecoder.decodeAuthenticate(
            authenticate.data
        )
        #expect(authenticateResponse == KafkaSASLAuthenticateResponse(
            correlationID: 5,
            errorCode: 0,
            errorMessage: nil,
            authBytes: Data()
        ))

        authenticate.append(Data([0]))
        #expect(throws: KafkaError.invalidResponse) {
            _ = try KafkaSASLResponseDecoder.decodeAuthenticate(authenticate.data)
        }
    }

    @Test("Rejects duplicate broker and topic metadata")
    func duplicateMetadata() {
        var brokerData = KafkaEncoder()
        brokerData.int32(7)
        brokerData.arrayCount(2)
        for _ in 0..<2 {
            brokerData.int32(2)
            brokerData.string("broker")
            brokerData.int32(9092)
        }
        brokerData.arrayCount(0)
        #expect(throws: KafkaError.invalidResponse) {
            _ = try KafkaMetadataDecoder.decodeResponse(brokerData.data)
        }

        var topicData = KafkaEncoder()
        topicData.int32(7)
        topicData.arrayCount(0)
        topicData.arrayCount(2)
        for _ in 0..<2 {
            topicData.int16(0)
            topicData.string("events")
            topicData.arrayCount(0)
        }
        #expect(throws: KafkaError.invalidResponse) {
            _ = try KafkaMetadataDecoder.decodeResponse(topicData.data)
        }

        var partitionData = KafkaEncoder()
        partitionData.int32(7)
        partitionData.arrayCount(0)
        partitionData.arrayCount(1)
        partitionData.int16(0)
        partitionData.string("events")
        partitionData.arrayCount(2)
        for _ in 0..<2 {
            partitionData.int16(0)
            partitionData.int32(3)
            partitionData.int32(2)
            partitionData.arrayCount(0)
            partitionData.arrayCount(0)
        }
        #expect(throws: KafkaError.invalidResponse) {
            _ = try KafkaMetadataDecoder.decodeResponse(partitionData.data)
        }
    }

    @Test("Decodes Metadata v1 broker and topic fields")
    func metadataV1Response() throws {
        var data = KafkaEncoder()
        data.int32(8) // correlation id
        data.arrayCount(1)
        data.int32(1)
        data.string("broker")
        data.int32(9092)
        data.nullableString(nil) // broker rack
        data.int32(1) // controller id
        data.arrayCount(1)
        data.int16(0)
        data.string("events")
        data.int8(0) // is_internal
        data.arrayCount(0)

        let response = try KafkaMetadataDecoder.decodeResponse(
            data.data,
            includesThrottleTime: false,
            includesBrokerRack: true,
            includesControllerMetadata: true,
            includesInternalTopicFlag: true
        )
        #expect(response.correlationID == 8)
        #expect(response.throttleTimeMilliseconds == nil)
        #expect(response.clusterID == nil)
        #expect(response.controllerID == 1)
        #expect(response.topics == [KafkaTopicMetadata(name: "events", partitions: [])])
    }

    @Test("Sorts Topic names for the sidebar")
    func topicListingOrder() {
        let topics = [
            KafkaTopicMetadata(name: "orders-10", partitions: []),
            KafkaTopicMetadata(name: "orders-2", partitions: []),
            KafkaTopicMetadata(name: "audit", partitions: []),
        ]

        #expect(
            KafkaWorkspaceSession.sortedTopics(topics).map(\.name)
                == ["audit", "orders-2", "orders-10"]
        )
    }

    @Test("Encodes and decodes ListOffsets v1 with throttle time")
    func listOffsets() throws {
        let request = KafkaListOffsetsRequestEncoder.encodeV1(
            replicaID: -1,
            topics: [
                KafkaListOffsetsRequestTopic(
                    name: "events",
                    partitions: [
                        KafkaListOffsetsRequestPartition(
                            partition: 2,
                            timestamp: -1
                        ),
                    ]
                ),
            ]
        )
        var requestDecoder = KafkaDecoder(data: request)
        #expect(try requestDecoder.int32() == -1)
        #expect(try requestDecoder.arrayCount() == 1)
        #expect(try requestDecoder.string() == "events")
        #expect(try requestDecoder.arrayCount() == 1)
        #expect(try requestDecoder.int32() == 2)
        #expect(try requestDecoder.int64() == -1)
        #expect(requestDecoder.remainingCount == 0)

        var responseData = KafkaEncoder()
        responseData.int32(13)
        responseData.int32(17)
        responseData.arrayCount(1)
        responseData.string("events")
        responseData.arrayCount(1)
        responseData.int32(2)
        responseData.int16(0)
        responseData.int64(1_700_000_000_000)
        responseData.int64(42)

        let response = try KafkaListOffsetsResponseDecoder.decodeV1(responseData.data)
        #expect(response.correlationID == 13)
        #expect(response.throttleTimeMilliseconds == 17)
        #expect(response.topics[0].name == "events")
        #expect(response.topics[0].partitions[0] == KafkaListOffsetsPartitionResponse(
            partition: 2,
            errorCode: 0,
            timestamp: 1_700_000_000_000,
            offset: 42
        ))
    }

    @Test("Decodes Fetch v4 nullable transaction and record fields")
    func fetchV4Response() throws {
        var data = KafkaEncoder()
        data.int32(91) // correlation id
        data.int32(23) // throttle time
        data.arrayCount(1)
        data.string("events")
        data.arrayCount(1)
        data.int32(2) // partition
        data.int16(0) // error code
        data.int64(100) // high watermark
        data.int64(98) // last stable offset
        data.int32(-1) // nullable aborted transactions
        data.bytes(nil) // nullable records

        let response = try KafkaFetchResponseDecoder.decode(data.data, version: 4)
        #expect(response.correlationID == 91)
        #expect(response.throttleTimeMilliseconds == 23)
        #expect(response.errorCode == nil)
        #expect(response.sessionID == nil)
        #expect(response.topics == [
            KafkaFetchTopicResponse(
                name: "events",
                partitions: [
                    KafkaFetchPartitionResponse(
                        partition: 2,
                        errorCode: 0,
                        highWatermark: 100,
                        records: nil,
                        lastStableOffset: 98,
                        logStartOffset: nil,
                        abortedTransactions: nil,
                        preferredReadReplica: nil
                    ),
                ]
            ),
        ])
    }

    @Test("Decodes Fetch v11 session and preferred replica fields")
    func fetchV11Response() throws {
        var data = KafkaEncoder()
        data.int32(91) // correlation id
        data.int32(23) // throttle time
        data.int16(0) // top-level error
        data.int32(44) // session id
        data.arrayCount(1)
        data.string("events")
        data.arrayCount(1)
        data.int32(2) // partition
        data.int16(0) // error code
        data.int64(100) // high watermark
        data.int64(98) // last stable offset
        data.int64(4) // log start offset
        data.int32(1) // one aborted transaction
        data.int64(7) // producer id
        data.int64(8) // first offset
        data.int32(3) // preferred read replica
        data.bytes(Data())

        let response = try KafkaFetchResponseDecoder.decode(data.data, version: 11)
        #expect(response.errorCode == 0)
        #expect(response.sessionID == 44)
        #expect(response.topics[0].partitions[0].lastStableOffset == 98)
        #expect(response.topics[0].partitions[0].logStartOffset == 4)
        #expect(response.topics[0].partitions[0].abortedTransactions == [
            KafkaAbortedTransaction(producerID: 7, firstOffset: 8),
        ])
        #expect(response.topics[0].partitions[0].preferredReadReplica == 3)
        #expect(response.topics[0].partitions[0].records == Data())
    }

    @Test("Encodes Fetch v7 session and forgotten topic fields")
    func fetchV7Request() throws {
        let request = KafkaFetchRequestEncoder.encodeV7(
            maximumWaitMilliseconds: 250,
            minimumBytes: 1,
            maximumBytes: 4096,
            sessionID: 12,
            sessionEpoch: 4,
            topics: [KafkaFetchV4RequestTopic(
                name: "events",
                partitions: [KafkaFetchV4RequestPartition(
                    partition: 2,
                    fetchOffset: 19,
                    logStartOffset: 3,
                    partitionMaximumBytes: 1024,
                )]
            )],
            forgottenTopics: [KafkaForgottenTopic(name: "old", partitions: [0, 1])],
            rackID: "rack-a"
        )
        var decoder = KafkaDecoder(data: request)
        #expect(try decoder.int32() == -1)
        #expect(try decoder.int32() == 250)
        #expect(try decoder.int32() == 1)
        #expect(try decoder.int32() == 4096)
        #expect(try decoder.int8() == 0)
        #expect(try decoder.int32() == 12)
        #expect(try decoder.int32() == 4)
        #expect(try decoder.arrayCount() == 1)
        #expect(try decoder.string() == "events")
        #expect(try decoder.arrayCount() == 1)
        #expect(try decoder.int32() == 2)
        #expect(try decoder.int64() == 19)
        #expect(try decoder.int64() == 3)
        #expect(try decoder.int32() == 1024)
        #expect(try decoder.arrayCount() == 1)
        #expect(try decoder.string() == "old")
        #expect(try decoder.arrayCount() == 2)
        #expect(try decoder.int32() == 0)
        #expect(try decoder.int32() == 1)
        #expect(try decoder.string() == "rack-a")
        #expect(decoder.remainingCount == 0)
    }

    @Test("Rejects duplicate Fetch partitions and trailing response bytes")
    func malformedFetchResponse() {
        var duplicate = KafkaEncoder()
        duplicate.int32(1)
        duplicate.arrayCount(1)
        duplicate.string("events")
        duplicate.arrayCount(2)
        for _ in 0..<2 {
            duplicate.int32(0)
            duplicate.int16(0)
            duplicate.int64(1)
            duplicate.bytes(nil)
        }
        #expect(throws: KafkaError.invalidResponse) {
            _ = try KafkaFetchResponseDecoder.decode(duplicate.data)
        }

        var trailing = KafkaEncoder()
        trailing.int32(1)
        trailing.arrayCount(0)
        trailing.append(Data([0]))
        #expect(throws: KafkaError.invalidResponse) {
            _ = try KafkaFetchResponseDecoder.decode(trailing.data)
        }
    }

    @Test("Rejects duplicate ListOffsets partitions and trailing bytes")
    func malformedListOffsetsResponse() {
        var duplicate = KafkaEncoder()
        duplicate.int32(1)
        duplicate.int32(0)
        duplicate.arrayCount(1)
        duplicate.string("events")
        duplicate.arrayCount(2)
        for _ in 0..<2 {
            duplicate.int32(0)
            duplicate.int16(0)
            duplicate.int64(0)
            duplicate.int64(0)
        }
        #expect(throws: KafkaError.invalidResponse) {
            _ = try KafkaListOffsetsResponseDecoder.decodeV1(duplicate.data)
        }

        var trailing = KafkaEncoder()
        trailing.int32(1)
        trailing.int32(0)
        trailing.arrayCount(0)
        trailing.append(Data([0]))
        #expect(throws: KafkaError.invalidResponse) {
            _ = try KafkaListOffsetsResponseDecoder.decodeV1(trailing.data)
        }
    }

    @Test("Rejects overflowing compact varints")
    func compactVarIntOverflow() {
        #expect(throws: KafkaError.invalidResponse) {
            var decoder = KafkaDecoder(data: Data(repeating: 0xff, count: 9) + Data([0x02]))
            _ = try decoder.unsignedVarInt()
        }
    }

    @Test("Rejects invalid negative nullable lengths")
    func invalidNegativeNullableLengths() {
        var stringData = KafkaEncoder()
        stringData.int16(-2)
        #expect(throws: KafkaError.invalidResponse) {
            var decoder = KafkaDecoder(data: stringData.data)
            _ = try decoder.nullableString()
        }

        var bytesData = KafkaEncoder()
        bytesData.int32(-2)
        #expect(throws: KafkaError.invalidResponse) {
            var decoder = KafkaDecoder(data: bytesData.data)
            _ = try decoder.bytes()
        }

        var arrayData = KafkaEncoder()
        arrayData.int32(.max)
        #expect(throws: KafkaError.invalidResponse) {
            var decoder = KafkaDecoder(data: arrayData.data)
            _ = try decoder.arrayCount()
        }
        #expect(throws: KafkaError.invalidResponse) {
            var decoder = KafkaDecoder(data: arrayData.data)
            _ = try decoder.nullableArrayCount()
        }
    }

    @Test("Decodes a magic v2 record batch with headers")
    func recordBatch() throws {
        var records = KafkaEncoder()
        // Record attributes is a fixed-width int8. Use a high-bit value here
        // to ensure the decoder does not accidentally consume the next field
        // as a zig-zag varint. Reserved record flags are ignored for browsing.
        records.int8(Int8(bitPattern: 0x80))
        records.int8(0) // timestamp delta
        records.int8(0) // offset delta
        records.int8(1) // null key, zig-zag -1
        records.int8(10) // value length 5, zig-zag 5
        records.append(Data("hello".utf8))
        records.int8(2) // one header
        records.int8(10) // header key length 5
        records.append(Data("trace".utf8))
        records.int8(4) // header value length 2
        records.append(Data("id".utf8))

        var batch = KafkaEncoder()
        batch.int64(100)
        let batchLength = 4 + 1 + 4 + 2 + 4 + 8 + 8 + 8 + 2 + 4 + 4
            + 1 + records.data.count
        batch.int32(Int32(batchLength))
        batch.int32(0)
        batch.int8(2)
        batch.int32(0)
        batch.int16(0)
        batch.int32(0)
        batch.int64(1_700_000_000_000)
        batch.int64(1_700_000_000_000)
        batch.int64(-1)
        batch.int16(0)
        batch.int32(0)
        batch.int32(1)
        batch.int8(Int8(records.data.count * 2)) // zig-zag record length
        batch.append(records.data)

        let messages = try KafkaRecordBatchDecoder.decode(
            batch.data,
            partition: 4
        )
        #expect(messages.count == 1)
        #expect(messages[0].partition == 4)
        #expect(messages[0].offset == 100)
        #expect(messages[0].timestamp == 1_700_000_000_000)
        #expect(messages[0].value == Data("hello".utf8))
        #expect(messages[0].headers == [
            KafkaHeader(key: "trace", value: Data("id".utf8)),
        ])
    }

    @Test("Skips Kafka transaction control batches")
    func controlRecordBatch() throws {
        var records = KafkaEncoder()
        records.int8(0) // record attributes, zig-zag 0
        records.int8(0) // timestamp delta
        records.int8(0) // offset delta
        records.int8(1) // null key, zig-zag -1
        records.int8(1) // null value, zig-zag -1
        records.int8(0) // no headers

        var batch = KafkaEncoder()
        batch.int64(100)
        let batchLength = 4 + 1 + 4 + 2 + 4 + 8 + 8 + 8 + 2 + 4 + 4
            + 1 + records.data.count
        batch.int32(Int32(batchLength))
        batch.int32(0)
        batch.int8(2)
        batch.int32(0)
        batch.int16(0x20) // CONTROL_BATCH
        batch.int32(0)
        batch.int64(1_700_000_000_000)
        batch.int64(1_700_000_000_000)
        batch.int64(-1)
        batch.int16(0)
        batch.int32(0)
        batch.int32(1)
        batch.int8(Int8(records.data.count * 2))
        batch.append(records.data)

        let result = try KafkaRecordBatchDecoder.decodeWithProgress(
            batch.data,
            partition: 4
        )
        #expect(result.messages.isEmpty)
        // Control records are hidden from the table, but their offsets still
        // advance the fetch cursor so a transaction-only batch cannot stall
        // subsequent reads.
        #expect(result.nextOffset == 101)
    }

    @Test("Rejects compressed record batches with an explicit error")
    func compressedBatch() {
        var batch = KafkaEncoder()
        batch.int64(0)
        batch.int32(49)
        batch.int32(0)
        batch.int8(2)
        batch.int32(0)
        batch.int16(1)
        batch.int32(0)
        batch.int64(0)
        batch.int64(0)
        batch.int64(-1)
        batch.int16(0)
        batch.int32(0)
        batch.int32(0)

        #expect(throws: KafkaError.unsupportedCompression) {
            _ = try KafkaRecordBatchDecoder.decode(batch.data, partition: 0)
        }
    }

    @Test("Rejects compressed legacy MessageSet entries")
    func compressedLegacyMessageSet() {
        var message = KafkaEncoder()
        message.int32(0) // CRC
        message.int8(0) // magic
        message.int8(1) // gzip compression
        message.bytes(nil)
        message.bytes(Data())

        var batch = KafkaEncoder()
        batch.int64(0)
        batch.int32(Int32(message.data.count))
        batch.append(message.data)

        #expect(throws: KafkaError.unsupportedCompression) {
            _ = try KafkaRecordBatchDecoder.decode(batch.data, partition: 0)
        }
    }

    @Test("Rejects trailing bytes inside a legacy MessageSet entry")
    func legacyEntryTrailingBytes() {
        var message = KafkaEncoder()
        message.int32(0) // CRC
        message.int8(0) // magic
        message.int8(0) // attributes
        message.bytes(nil)
        message.bytes(Data())
        message.int8(-1) // outside the message body but inside its length

        var batch = KafkaEncoder()
        batch.int64(0)
        batch.int32(Int32(message.data.count))
        batch.append(message.data)

        #expect(throws: KafkaError.invalidResponse) {
            _ = try KafkaRecordBatchDecoder.decode(batch.data, partition: 0)
        }
    }

    @Test("Rejects trailing bytes inside a magic v2 record batch")
    func recordBatchTrailingBytes() {
        var batch = KafkaEncoder()
        batch.int64(0)
        // Header (49 bytes) plus one trailing byte, but record count is zero.
        batch.int32(50)
        batch.int32(0) // partition leader epoch
        batch.int8(2) // magic
        batch.int32(0) // CRC
        batch.int16(0) // attributes
        batch.int32(0) // last offset delta
        batch.int64(0) // first timestamp
        batch.int64(0) // max timestamp
        batch.int64(-1) // producer id
        batch.int16(0) // producer epoch
        batch.int32(0) // base sequence
        batch.int32(0) // record count
        batch.int8(-1)

        #expect(throws: KafkaError.invalidResponse) {
            _ = try KafkaRecordBatchDecoder.decode(batch.data, partition: 0)
        }
    }

    @Test("Rejects record batch offset overflow")
    func recordBatchOffsetOverflow() {
        var batch = KafkaEncoder()
        batch.int64(.max)
        batch.int32(49)
        batch.int32(0)
        batch.int8(2)
        batch.int32(0)
        batch.int16(0)
        batch.int32(1)
        batch.int64(0)
        batch.int64(0)
        batch.int64(-1)
        batch.int16(0)
        batch.int32(0)
        batch.int32(0)

        #expect(throws: KafkaError.invalidResponse) {
            _ = try KafkaRecordBatchDecoder.decode(batch.data, partition: 0)
        }
    }

    @Test("Accepts signed timestamp deltas in record batches")
    func signedTimestampDelta() throws {
        var record = KafkaEncoder()
        record.int8(0) // record attributes
        record.int8(19) // timestamp delta -10 (zig-zag)
        record.int8(0) // offset delta
        record.int8(1) // null key
        record.int8(1) // null value
        record.int8(0) // no headers

        var batch = KafkaEncoder()
        batch.int64(0)
        let batchLength = 4 + 1 + 4 + 2 + 4 + 8 + 8 + 8 + 2 + 4 + 4
            + 1 + record.data.count
        batch.int32(Int32(batchLength))
        batch.int32(0) // partition leader epoch
        batch.int8(2) // magic
        batch.int32(0) // CRC
        batch.int16(0) // attributes
        batch.int32(0) // last offset delta
        batch.int64(1_000) // first timestamp
        batch.int64(1_000) // max timestamp
        batch.int64(-1) // producer id
        batch.int16(0) // producer epoch
        batch.int32(0) // base sequence
        batch.int32(1) // record count
        batch.int8(Int8(record.data.count * 2)) // record length
        batch.append(record.data)

        let messages = try KafkaRecordBatchDecoder.decode(batch.data, partition: 0)
        #expect(messages.count == 1)
        #expect(messages[0].timestamp == 990)
    }

    @Test("Rejects a record batch whose last offset delta skips records")
    func recordBatchOffsetDeltaMismatch() {
        var record = KafkaEncoder()
        record.int8(0)
        record.int8(0)
        record.int8(0)
        record.int8(1)
        record.int8(1)
        record.int8(0)

        var batch = KafkaEncoder()
        batch.int64(0)
        let batchLength = 4 + 1 + 4 + 2 + 4 + 8 + 8 + 8 + 2 + 4 + 4
            + 1 + record.data.count
        batch.int32(Int32(batchLength))
        batch.int32(0)
        batch.int8(2)
        batch.int32(0)
        batch.int16(0)
        batch.int32(1) // header says last delta is 1
        batch.int64(0)
        batch.int64(0)
        batch.int64(-1)
        batch.int16(0)
        batch.int32(0)
        batch.int32(1)
        batch.int8(Int8(record.data.count * 2))
        batch.append(record.data) // actual only record has offset delta 0

        #expect(throws: KafkaError.invalidResponse) {
            _ = try KafkaRecordBatchDecoder.decode(batch.data, partition: 0)
        }
    }

    @Test("Applies Kafka filters before pagination and count bounds")
    func filteredPaginationWindow() {
        let messages = [
            KafkaMessage(
                partition: 0,
                offset: 0,
                timestamp: nil,
                key: nil,
                value: Data("skip".utf8),
                headers: []
            ),
            KafkaMessage(
                partition: 0,
                offset: 1,
                timestamp: nil,
                key: nil,
                value: Data("keep".utf8),
                headers: []
            ),
            KafkaMessage(
                partition: 0,
                offset: 2,
                timestamp: nil,
                key: nil,
                value: Data("skip".utf8),
                headers: []
            ),
            KafkaMessage(
                partition: 0,
                offset: 3,
                timestamp: nil,
                key: nil,
                value: Data("keep".utf8),
                headers: []
            ),
        ]
        let filter = WorkspaceDatabaseDataFilter(conditions: [
            WorkspaceDatabaseDataFilterCondition(
                columnName: "value",
                columnKind: .text,
                operation: .equal,
                value: "keep"
            ),
        ])

        let visible = KafkaWorkspaceSession.filteredMessages(
            messages,
            using: .none,
            filter: filter
        )
        #expect(visible.map(\.offset) == [1, 3])
        #expect(visible.count == 2)
        #expect(!KafkaWorkspaceSession.hasEnoughRows(
            messages,
            target: 3,
            sort: .none,
            filter: filter
        ))
        #expect(KafkaWorkspaceSession.hasEnoughRows(
            messages,
            target: 2,
            sort: .none,
            filter: filter
        ))
    }

    @Test("Bounds Kafka fetch cycles even when sorting wants the full topic")
    func fetchCycleBudget() {
        #expect(KafkaWorkspaceSession.fetchCycleLimit(readUntilExhausted: false) > 0)
        #expect(KafkaWorkspaceSession.fetchCycleLimit(readUntilExhausted: true) > 0)
        #expect(KafkaWorkspaceSession.shouldFetchMore(
            cycles: 0,
            hasEnoughRows: true,
            hasUnexhaustedPartitions: true,
            readUntilExhausted: false
        ) == false)
        #expect(KafkaWorkspaceSession.shouldFetchMore(
            cycles: 0,
            hasEnoughRows: true,
            hasUnexhaustedPartitions: true,
            readUntilExhausted: true
        ))
        #expect(KafkaWorkspaceSession.shouldFetchMore(
            cycles: KafkaWorkspaceSession.fetchCycleLimit(readUntilExhausted: true),
            hasEnoughRows: false,
            hasUnexhaustedPartitions: true,
            readUntilExhausted: true
        ) == false)
        #expect(KafkaWorkspaceSession.shouldFetchMore(
            cycles: 0,
            hasEnoughRows: false,
            hasUnexhaustedPartitions: false,
            readUntilExhausted: true
        ) == false)
        #expect(KafkaWorkspaceSession.shouldExhaustEmptyFetch(
            highWatermark: 10,
            startOffset: 10
        ))
        #expect(!KafkaWorkspaceSession.shouldExhaustEmptyFetch(
            highWatermark: 11,
            startOffset: 10
        ))
    }

    @Test("Sorts Kafka text columns with stable partition and offset ties")
    func textColumnSorting() {
        let messages = [
            KafkaMessage(
                partition: 1,
                offset: 4,
                timestamp: nil,
                key: Data("beta".utf8),
                value: Data("z".utf8),
                headers: [KafkaHeader(key: "trace", value: Data("2".utf8))]
            ),
            KafkaMessage(
                partition: 0,
                offset: 9,
                timestamp: nil,
                key: Data("alpha".utf8),
                value: Data("a".utf8),
                headers: [KafkaHeader(key: "trace", value: Data("1".utf8))]
            ),
            KafkaMessage(
                partition: 0,
                offset: 2,
                timestamp: nil,
                key: Data("beta".utf8),
                value: Data("m".utf8),
                headers: [KafkaHeader(key: "trace", value: Data("3".utf8))]
            ),
        ]

        let keyAscending = KafkaWorkspaceSession.filteredMessages(
            messages,
            using: .ascending(columnName: "key"),
            filter: .empty
        )
        #expect(keyAscending.map(\.offset) == [9, 2, 4])

        let valueDescending = KafkaWorkspaceSession.filteredMessages(
            messages,
            using: .descending(columnName: "value"),
            filter: .empty
        )
        #expect(valueDescending.map(\.offset) == [4, 2, 9])

        let headersAscending = KafkaWorkspaceSession.filteredMessages(
            messages,
            using: .ascending(columnName: "headers"),
            filter: .empty
        )
        #expect(headersAscending.map(\.offset) == [9, 4, 2])

        let timestampTies = [
            KafkaMessage(
                partition: 2,
                offset: 1,
                timestamp: 100,
                key: nil,
                value: nil,
                headers: []
            ),
            KafkaMessage(
                partition: 1,
                offset: 1,
                timestamp: 100,
                key: nil,
                value: nil,
                headers: []
            ),
        ]
        #expect(KafkaWorkspaceSession.filteredMessages(
            timestampTies,
            using: .ascending(columnName: "timestamp"),
            filter: .empty
        ).map(\.partition) == [1, 2])
    }
}
