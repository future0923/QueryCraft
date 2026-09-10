import CHiredis
import Darwin
import Foundation
import QueryCraftFeature

final class RedisClient: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "io.github.future0923.QueryCraft.Driver.RedisClient",
        qos: .userInitiated
    )
    private let configuration: RedisConnectionConfiguration
    private var context: UnsafeMutablePointer<redisContext>?
    private var selectedDatabaseIndex: Int?

    init(configuration: RedisConnectionConfiguration) {
        self.configuration = configuration
    }

    func connect() async throws {
        try await runOnQueue {
            if self.context != nil { return }
            let context = try self.openConnection()
            do {
                try self.authenticate(on: context)
                _ = try? self.command(["HELLO", "3"], context: context)
                try self.selectDatabase(
                    self.configuration.databaseIndex,
                    context: context
                )
                self.context = context
                self.selectedDatabaseIndex = self.configuration.databaseIndex
            } catch {
                redisFree(context)
                throw error
            }
        }
    }

    func isConnected() async -> Bool {
        await runOnQueueReturningFalseOnError {
            guard let context = self.context else { return false }
            let reply = try self.command(["PING"], context: context)
            guard case .simpleString(let value) = reply else { return false }
            return value.uppercased() == "PONG"
        }
    }

    func execute(
        _ arguments: [String],
        databaseIndex: Int? = nil
    ) async throws -> RedisReplyValue {
        try await runOnQueue {
            guard let context = self.context else {
                throw RedisClientError(message: "Redis is not connected.")
            }
            if let databaseIndex,
               databaseIndex != self.selectedDatabaseIndex
            {
                try self.selectDatabase(databaseIndex, context: context)
                self.selectedDatabaseIndex = databaseIndex
            }
            return try self.command(arguments, context: context)
        }
    }

    func executePipeline(
        _ commands: [[String]],
        databaseIndex: Int? = nil
    ) async throws -> [RedisReplyValue] {
        guard !commands.isEmpty else { return [] }
        guard commands.allSatisfy({ !$0.isEmpty }) else {
            throw RedisWorkspaceError.invalidCommand
        }
        return try await runOnQueue {
            guard let context = self.context else {
                throw RedisClientError(message: "Redis is not connected.")
            }
            if let databaseIndex,
               databaseIndex != self.selectedDatabaseIndex
            {
                try self.selectDatabase(databaseIndex, context: context)
                self.selectedDatabaseIndex = databaseIndex
            }
            do {
                for command in commands {
                    try self.appendRawCommand(
                        command.map { Data($0.utf8) },
                        context: context
                    )
                }
                return try commands.map { _ in
                    try self.readRawReply(context: context).redisReplyValue
                }
            } catch {
                self.invalidateConnection(context)
                throw error
            }
        }
    }

    func executeRaw(
        _ arguments: [RedisBinaryValue],
        databaseIndex: Int? = nil
    ) async throws -> RedisRawReplyValue {
        try await runOnQueue {
            guard let context = self.context else {
                throw RedisClientError(message: "Redis is not connected.")
            }
            if let databaseIndex,
               databaseIndex != self.selectedDatabaseIndex
            {
                try self.selectDatabase(databaseIndex, context: context)
                self.selectedDatabaseIndex = databaseIndex
            }
            return try self.rawCommand(
                arguments.map(\.data),
                context: context
            )
        }
    }

    func executeTransaction(
        _ commands: [[String]],
        databaseIndex: Int
    ) async throws {
        guard !commands.isEmpty else { return }
        try await runOnQueue {
            guard let context = self.context else {
                throw RedisClientError(message: "Redis is not connected.")
            }
            if databaseIndex != self.selectedDatabaseIndex {
                try self.selectDatabase(databaseIndex, context: context)
                self.selectedDatabaseIndex = databaseIndex
            }

            try self.requireSuccess(self.command(["MULTI"], context: context))
            do {
                for arguments in commands {
                    let reply = try self.command(arguments, context: context)
                    try self.requireSuccess(reply)
                }
                let reply = try self.command(["EXEC"], context: context)
                guard let results = reply.collectionValues else {
                    throw RedisWorkspaceError.invalidReply("EXEC")
                }
                guard results.count == commands.count else {
                    throw RedisWorkspaceError.invalidReply("EXEC")
                }
                if case .error(let message)? = results.first(where: {
                    if case .error = $0 { return true }
                    return false
                }) {
                    throw RedisClientError(message: message)
                }
            } catch {
                _ = try? self.command(["DISCARD"], context: context)
                throw error
            }
        }
    }

    func executeOptimisticMutation(
        _ request: RedisOptimisticMutationRequest
    ) async throws {
        guard !request.operations.isEmpty else { return }
        try await runOnQueue {
            guard let context = self.context else {
                throw RedisClientError(message: "Redis is not connected.")
            }
            let databaseIndex = request.reference.databaseIndex
            if databaseIndex != self.selectedDatabaseIndex {
                try self.selectDatabase(databaseIndex, context: context)
                self.selectedDatabaseIndex = databaseIndex
            }
            let key = Data(request.reference.name.utf8)
            _ = try self.rawCommand(
                [Data("WATCH".utf8), key],
                context: context
            )
            do {
                try self.validate(
                    request.assertions,
                    key: key,
                    reference: request.reference,
                    context: context
                )
                try self.requireRawSuccess(
                    self.rawCommand([Data("MULTI".utf8)], context: context)
                )
                var queuedCommandCount = 0
                for operation in request.operations {
                    switch operation {
                    case let .command(invocation):
                        try self.requireRawSuccess(
                            self.rawCommand(
                                invocation.arguments.map(\.data),
                                context: context
                            )
                        )
                        queuedCommandCount += 1
                    case let .deleteListElement(index, _):
                        let marker = Data(
                            "querycraft:list-delete:\(UUID().uuidString)".utf8
                        )
                        try self.requireRawSuccess(
                            self.rawCommand(
                                [
                                    Data("LSET".utf8), key,
                                    Data(String(index).utf8), marker,
                                ],
                                context: context
                            )
                        )
                        try self.requireRawSuccess(
                            self.rawCommand(
                                [
                                    Data("LREM".utf8), key,
                                    Data("1".utf8), marker,
                                ],
                                context: context
                            )
                        )
                        queuedCommandCount += 2
                    }
                }
                let reply = try self.rawCommand(
                    [Data("EXEC".utf8)],
                    context: context
                )
                if case .null = reply {
                    throw RedisWorkspaceError.mutationConflict(
                        request.reference.name
                    )
                }
                guard let results = reply.collectionValues,
                      results.count == queuedCommandCount
                else {
                    throw RedisWorkspaceError.invalidReply("EXEC")
                }
                if case let .error(message)? = results.first(where: {
                    if case .error = $0 { return true }
                    return false
                }) {
                    throw RedisClientError(message: message)
                }
            } catch {
                _ = try? self.rawCommand(
                    [Data("DISCARD".utf8)],
                    context: context
                )
                _ = try? self.rawCommand(
                    [Data("UNWATCH".utf8)],
                    context: context
                )
                throw error
            }
        }
    }

    func close() async {
        await runOnQueueIgnoringError {
            if let context = self.context {
                redisFree(context)
                self.context = nil
                self.selectedDatabaseIndex = nil
            }
        }
    }

    private func openConnection() throws -> UnsafeMutablePointer<redisContext> {
        let timeout = timeval(tv_sec: 10, tv_usec: 0)
        let context = configuration.host.withCString { host in
            redisConnectWithTimeout(host, Int32(configuration.port), timeout)
        }
        guard let context else {
            throw RedisClientError(
                message: "Failed to initialize the Redis connection."
            )
        }
        guard context.pointee.err == 0 else {
            let error = error(from: context)
            redisFree(context)
            throw error
        }
        guard redisSetTimeout(context, timeout) == REDIS_OK else {
            let error = error(from: context)
            redisFree(context)
            throw error
        }
        return context
    }

    private func authenticate(
        on context: UnsafeMutablePointer<redisContext>
    ) throws {
        guard let password = configuration.password, !password.isEmpty else {
            return
        }
        let arguments = configuration.username.isEmpty
            ? ["AUTH", password]
            : ["AUTH", configuration.username, password]
        try requireSuccess(command(arguments, context: context))
    }

    private func selectDatabase(
        _ index: Int,
        context: UnsafeMutablePointer<redisContext>
    ) throws {
        try requireSuccess(command(["SELECT", String(index)], context: context))
    }

    private func requireSuccess(_ reply: RedisReplyValue) throws {
        if case .error(let message) = reply {
            throw RedisClientError(message: message)
        }
    }

    private func requireRawSuccess(_ reply: RedisRawReplyValue) throws {
        if case let .error(message) = reply {
            throw RedisClientError(message: message)
        }
    }

    private func validate(
        _ assertions: [RedisMutationAssertion],
        key: Data,
        reference: RedisKeyReference,
        context: UnsafeMutablePointer<redisContext>
    ) throws {
        for assertion in assertions {
            let isValid: Bool
            switch assertion {
            case let .keyType(expected):
                let reply = try rawCommand(
                    [Data("TYPE".utf8), key],
                    context: context
                )
                isValid = reply.stringValue == expected.rawValue
            case let .elementCount(expected):
                let command = switch reference.type {
                case .list: "LLEN"
                case .hash: "HLEN"
                case .set: "SCARD"
                case .sortedSet: "ZCARD"
                case .string: "STRLEN"
                case .stream: "XLEN"
                case .module, .unknown, .none: "EXISTS"
                }
                let reply = try rawCommand(
                    [Data(command.utf8), key],
                    context: context
                )
                isValid = reply.integerValue == Int64(expected)
            case let .stringValue(expected):
                let reply = try rawCommand(
                    [Data("GET".utf8), key],
                    context: context
                )
                isValid = reply.dataValue == expected.data
            case let .listElement(index, expected):
                let reply = try rawCommand(
                    [
                        Data("LINDEX".utf8), key,
                        Data(String(index).utf8),
                    ],
                    context: context
                )
                isValid = reply.dataValue == expected.data
            case let .hashValue(field, expected):
                let reply = try rawCommand(
                    [Data("HGET".utf8), key, field.data],
                    context: context
                )
                isValid = optionalData(reply) == expected?.data
            case let .setMembership(member, expected):
                let reply = try rawCommand(
                    [Data("SISMEMBER".utf8), key, member.data],
                    context: context
                )
                isValid = (reply.integerValue == 1) == expected
            case let .sortedSetScore(member, expected):
                let reply = try rawCommand(
                    [Data("ZSCORE".utf8), key, member.data],
                    context: context
                )
                isValid = reply.stringValue == expected
                    || (expected == nil && optionalData(reply) == nil)
            }
            guard isValid else {
                throw RedisWorkspaceError.mutationConflict(reference.name)
            }
        }
    }

    private func optionalData(_ reply: RedisRawReplyValue) -> Data? {
        if case .null = reply { return nil }
        return reply.dataValue
    }

    private func command(
        _ arguments: [String],
        context: UnsafeMutablePointer<redisContext>
    ) throws -> RedisReplyValue {
        try rawCommand(
            arguments.map { Data($0.utf8) },
            context: context
        ).redisReplyValue
    }

    private func rawCommand(
        _ arguments: [Data],
        context: UnsafeMutablePointer<redisContext>
    ) throws -> RedisRawReplyValue {
        guard !arguments.isEmpty else {
            throw RedisWorkspaceError.invalidCommand
        }

        let rawReply = withRawArgumentVectors(arguments) { pointers, lengths in
            pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                lengths.withUnsafeMutableBufferPointer { lengthBuffer in
                    redisCommandArgv(
                        context,
                        Int32(arguments.count),
                        pointerBuffer.baseAddress,
                        lengthBuffer.baseAddress
                    )
                }
            }
        }
        guard let rawReply else {
            throw error(from: context)
        }
        defer { freeReplyObject(rawReply) }
        let reply = rawReply.assumingMemoryBound(to: redisReply.self)
        return decodeRaw(reply)
    }

    private func appendRawCommand(
        _ arguments: [Data],
        context: UnsafeMutablePointer<redisContext>
    ) throws {
        guard !arguments.isEmpty else {
            throw RedisWorkspaceError.invalidCommand
        }
        let status = withRawArgumentVectors(arguments) { pointers, lengths in
            pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                lengths.withUnsafeMutableBufferPointer { lengthBuffer in
                    redisAppendCommandArgv(
                        context,
                        Int32(arguments.count),
                        pointerBuffer.baseAddress,
                        lengthBuffer.baseAddress
                    )
                }
            }
        }
        guard status == REDIS_OK else {
            throw error(from: context)
        }
    }

    private func readRawReply(
        context: UnsafeMutablePointer<redisContext>
    ) throws -> RedisRawReplyValue {
        var rawReply: UnsafeMutableRawPointer?
        guard redisGetReply(context, &rawReply) == REDIS_OK,
              let rawReply
        else {
            throw error(from: context)
        }
        defer { freeReplyObject(rawReply) }
        return decodeRaw(rawReply.assumingMemoryBound(to: redisReply.self))
    }

    private func withRawArgumentVectors<Result>(
        _ arguments: [Data],
        _ body: (
            inout [UnsafePointer<CChar>?],
            inout [Int]
        ) -> Result
    ) -> Result {
        let allocatedArguments = arguments.map { argument in
            let capacity = max(1, argument.count)
            let pointer = UnsafeMutablePointer<CChar>.allocate(
                capacity: capacity
            )
            if !argument.isEmpty {
                argument.withUnsafeBytes { bytes in
                    guard let source = bytes.baseAddress else { return }
                    pointer.initialize(
                        from: source.assumingMemoryBound(to: CChar.self),
                        count: argument.count
                    )
                }
            }
            return pointer
        }
        defer {
            allocatedArguments.forEach { pointer in
                pointer.deallocate()
            }
        }
        var argumentPointers: [UnsafePointer<CChar>?] = allocatedArguments.map {
            UnsafePointer($0)
        }
        var argumentLengths = arguments.map(\.count)
        return body(&argumentPointers, &argumentLengths)
    }

    private func invalidateConnection(
        _ failedContext: UnsafeMutablePointer<redisContext>
    ) {
        guard context == failedContext else { return }
        redisFree(failedContext)
        context = nil
        selectedDatabaseIndex = nil
    }

    private func decodeRaw(
        _ reply: UnsafeMutablePointer<redisReply>
    ) -> RedisRawReplyValue {
        switch reply.pointee.type {
        case REDIS_REPLY_STATUS:
            .status(string(from: reply))
        case REDIS_REPLY_STRING, REDIS_REPLY_VERB, REDIS_REPLY_BIGNUM:
            .blob(data(from: reply))
        case REDIS_REPLY_ERROR:
            .error(string(from: reply))
        case REDIS_REPLY_INTEGER:
            .integer(reply.pointee.integer)
        case REDIS_REPLY_DOUBLE:
            .double(reply.pointee.dval)
        case REDIS_REPLY_BOOL:
            .boolean(reply.pointee.integer != 0)
        case REDIS_REPLY_NIL:
            .null
        case REDIS_REPLY_SET:
            .set(elements(from: reply))
        case REDIS_REPLY_MAP:
            .map(mapEntries(from: reply))
        case REDIS_REPLY_ARRAY, REDIS_REPLY_ATTR, REDIS_REPLY_PUSH:
            .array(elements(from: reply))
        default:
            .error("Unsupported Redis reply type \(reply.pointee.type).")
        }
    }

    private func elements(
        from reply: UnsafeMutablePointer<redisReply>
    ) -> [RedisRawReplyValue] {
        guard let elements = reply.pointee.element else { return [] }
        return (0..<Int(reply.pointee.elements)).compactMap { index in
            elements[index].map(decodeRaw)
        }
    }

    private func mapEntries(
        from reply: UnsafeMutablePointer<redisReply>
    ) -> [(RedisRawReplyValue, RedisRawReplyValue)] {
        let values = elements(from: reply)
        return stride(from: 0, to: values.count - 1, by: 2).map { index in
            (values[index], values[index + 1])
        }
    }

    private func data(
        from reply: UnsafeMutablePointer<redisReply>
    ) -> Data {
        guard let bytes = reply.pointee.str else { return Data() }
        return Data(bytes: bytes, count: Int(reply.pointee.len))
    }

    private func string(
        from reply: UnsafeMutablePointer<redisReply>
    ) -> String {
        String(decoding: data(from: reply), as: UTF8.self)
    }

    private func error(
        from context: UnsafeMutablePointer<redisContext>
    ) -> RedisClientError {
        let message = withUnsafeBytes(of: context.pointee.errstr) { buffer in
            guard let baseAddress = buffer.baseAddress else { return "" }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
        return RedisClientError(
            message: message.isEmpty ? "Redis connection failed." : message
        )
    }

    private func runOnQueue<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runOnQueueIgnoringError(
        _ operation: @escaping @Sendable () throws -> Void
    ) async {
        _ = try? await runOnQueue(operation)
    }

    private func runOnQueueReturningFalseOnError(
        _ operation: @escaping @Sendable () throws -> Bool
    ) async -> Bool {
        (try? await runOnQueue(operation)) ?? false
    }
}
