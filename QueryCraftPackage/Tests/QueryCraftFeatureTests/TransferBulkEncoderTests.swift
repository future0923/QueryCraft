import Foundation
import Testing
#if os(iOS)
import QueryCraftMobileCore
@testable import QueryCraftMobileProof
#else
@testable import QueryCraftFeature
#endif

func consumeNativeStream(_ stream: WorkspaceNativeBulkStream, readSize: Int = 7) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var result = Data(), buffer = [UInt8](repeating: 0, count: readSize)
                while true {
                    let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                    if count == 0 { break }
                    result.append(contentsOf: buffer.prefix(count))
                }
                continuation.resume(returning: result)
            } catch { continuation.resume(throwing: error) }
        }
    }
}

struct TransferBulkEncoderTests {
    private func column(_ name: String, _ type: String) -> WorkspaceDatabaseColumn {
        .init(name: name, type: type, collation: nil, isNullable: true, key: "", defaultValue: nil, extra: "", comment: "")
    }

    private func encode(_ encoder: TransferBulkEncoder, rows: [WorkspaceDatabaseDataRow]) async throws -> Data {
        let stream = WorkspaceNativeBulkStream()
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                do { try await encoder.send(rows: rows, to: stream); stream.finish(); return Data() }
                catch { stream.fail(error); throw error }
            }
            group.addTask { try await consumeNativeStream(stream) }
            var result = Data()
            do { for try await value in group { if !value.isEmpty { result = value } }; return result }
            catch { stream.fail(error); group.cancelAll(); throw error }
        }
    }

    @Test("Native framing distinguishes NULL, empty, literal NULL marker and COPY end marker", arguments: [DatabaseType.mysql, .postgresql])
    func escaping(type: DatabaseType) async throws {
        let cols = [column("text", "text"), column("id", "bigint"), column("amount", "decimal(30,9)")]
        let encoder = try TransferBulkEncoder(columns: cols, targetColumns: cols, sourceType: type, targetType: type,
                                              endpoint: .init(database: "db", schema: type == .postgresql ? "s" : ""), name: "a.b",
                                              format: type == .postgresql ? .postgresqlCopyText : .mysqlLocalTSV)
        let values: [WorkspaceDatabaseDataCell] = [.null, .text(""), .text("\\N"), .text("\\."), .text("NULL"), .text("数据🙂'\u{301}\\\u{301}\t\n\r\u{8}")]
        let rows = values.enumerated().map { WorkspaceDatabaseDataRow(id: $0.offset, values: [$0.element, .text("9007199254740993"), .text("123456789012345678901.123456789")]) }
        let body = String(decoding: try await encode(encoder, rows: rows), as: UTF8.self)
        let suffix = "\t9007199254740993\t123456789012345678901.123456789\n"
        let golden = ["\\N", "", "\\\\N", "\\\\.", "NULL", "数据🙂'\u{301}\\\\\u{301}\\t\\n\\r\\b"].map { $0 + suffix }.joined()
        #expect(body == golden)
        #expect(encoder.sql.contains(type == .postgresql ? "\"s\".\"a.b\"" : "`db`.`a.b`"))
        #expect(!encoder.sql.contains("IGNORE"))
    }

    @Test("Raw binary, empty binary and booleans survive both native targets", arguments: [DatabaseType.mysql, .postgresql])
    func binary(type: DatabaseType) async throws {
        let source = [column("bytes", "bytea"), column("enabled", "boolean")]
        let target = [column("enabled", type == .mysql ? "tinyint(1)" : "boolean"), column("bytes", type == .mysql ? "blob" : "bytea")]
        let encoder = try TransferBulkEncoder(columns: source, targetColumns: target, sourceType: .postgresql, targetType: type,
                                              endpoint: .init(database: "db", schema: "s"), name: "t",
                                              format: type == .postgresql ? .postgresqlCopyText : .mysqlLocalTSV)
        let rows: [WorkspaceDatabaseDataRow] = [.init(id: 0, values: [.text("\\x00ff80"), .text("t")]), .init(id: 1, values: [.text("\\x"), .text("false")]), .init(id: 2, values: [.null, .null])]
        let body = String(decoding: try await encode(encoder, rows: rows), as: UTF8.self)
        let prefix = type == .postgresql ? "\\\\x" : ""
        #expect(body == "\(prefix)00ff80\t1\n\(prefix)\t0\n\\N\t\\N\n")
        if type == .mysql { #expect(encoder.sql.contains("`bytes` = UNHEX(@qc_0)")) }
    }

    @Test("Oversized rows stream across bounded chunks without corrupting UTF-8 or escapes")
    func wideRow() async throws {
        let cols = [column("text", "text")]
        let encoder = try TransferBulkEncoder(columns: cols, targetColumns: cols, sourceType: .mysql, targetType: .mysql,
                                              endpoint: .init(database: "db"), name: "t", format: .mysqlLocalTSV)
        let text = String(repeating: "数据🙂\\\t", count: 100_000)
        let body = try await encode(encoder, rows: [.init(id: 0, values: [.text(text)])])
        #expect(body == Data((String(repeating: "数据🙂\\\\\\t", count: 100_000) + "\n").utf8))
    }

    @Test("Invalid binary and PostgreSQL NUL fail the stream rather than emitting lossy values")
    func rejectedValues() async throws {
        for (source, value) in [(column("v", "blob"), WorkspaceDatabaseDataCell.text("ＦＦ")), (column("v", "blob"), .binary(byteCount: 1000, preview: [0])), (column("v", "text"), .text("a\0b"))] {
            let target = column("v", source.type == "blob" ? "bytea" : "text")
            let encoder = try TransferBulkEncoder(columns: [source], targetColumns: [target], sourceType: .mysql, targetType: .postgresql,
                                                  endpoint: .init(database: "db", schema: "s"), name: "t", format: .postgresqlCopyText)
            await #expect(throws: (any Error).self) { try await encode(encoder, rows: [.init(id: 0, values: [value])]) }
        }
    }

    @Test("A failed consumer releases the suspended producer, and later sends fail immediately")
    func failedConsumer() async throws {
        let stream = WorkspaceNativeBulkStream()
        let sender = Task { try await stream.send(Data([1, 2, 3])) }
        stream.fail(WorkspaceNativeBulkError.invalidLocalRequest)
        await #expect(throws: (any Error).self) { try await sender.value }
        await #expect(throws: (any Error).self) { try await stream.send(Data([4])) }
    }

    @Test("Cancellation wakes a waiting C consumer and the backpressured Swift sender")
    func cancellation() async throws {
        let stream = WorkspaceNativeBulkStream()
        let consumer = Task { try await consumeNativeStream(stream) }
        let sender = Task { try await stream.send(Data(repeating: 1, count: 300_000)) }
        sender.cancel()
        await #expect(throws: CancellationError.self) { try await sender.value }
        // send may have been cancelled before its cancellation handler was installed.
        stream.fail(CancellationError())
        await #expect(throws: CancellationError.self) { try await consumer.value }
    }

    @Test("Transfer source batches finish without losing the final prefetched batch")
    func batchChannel() async throws {
        let channel = WorkspaceTransferBatchChannel()
        let producer = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global().async {
                    do {
                        for index in 0..<23 {
                            try channel.send(.init(columns: [.init(id: 0, name: "id")], rows: [.init(id: index, values: [.text(String(index))])]))
                        }
                        channel.finish(); continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        var ids: [Int] = []
        while let batch = try await channel.next() { ids += batch.rows.map(\.id) }
        try await producer.value
        #expect(ids == Array(0..<23))
    }

    @Test("Failing a bounded source channel releases a blocked producer and consumer")
    func batchFailure() async throws {
        let channel = WorkspaceTransferBatchChannel()
        try channel.send(.init(columns: [], rows: []))
        let producer = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global().async {
                    do { try channel.send(.init(columns: [], rows: [])); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
        channel.fail(CancellationError())
        await #expect(throws: CancellationError.self) { try await producer.value }
        await #expect(throws: CancellationError.self) { try await channel.next() }
    }

    @Test("Quoted identifiers double ASCII quotes even before combining marks")
    func identifierEscapes() {
        #expect(WorkspaceSQLExportDialect.mysql.identifier("a`\u{301}b") == "`a``\u{301}b`")
        #expect(WorkspaceSQLExportDialect.postgresql.identifier("a\"\u{301}b") == "\"a\"\"\u{301}b\"")
    }
}
