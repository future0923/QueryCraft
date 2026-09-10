import Foundation

struct RedisKeyMutationPlan: Equatable, Sendable {
    let commands: [RedisCommandInvocation]
    let optimisticRequest: RedisOptimisticMutationRequest?

    static func make(
        details: RedisKeyDetails,
        stringValue: String,
        rows: [RedisKeyEditableRow],
        expirationMode: RedisKeyExpirationMode,
        ttlMillisecondsText: String,
        expectedElementCount: Int? = nil,
        stringData: RedisBinaryValue? = nil,
        originalStringData: RedisBinaryValue? = nil
    ) throws -> Self {
        let valuePlan = try valuePlan(
            details: details,
            stringValue: stringValue,
            rows: rows,
            expectedElementCount: expectedElementCount,
            stringData: stringData,
            originalStringData: originalStringData
        )
        let expiration = try expirationCommands(
            details: details,
            expirationMode: expirationMode,
            ttlMillisecondsText: ttlMillisecondsText
        )
        let commands = valuePlan.commands + expiration
        guard let request = valuePlan.request else {
            return Self(commands: commands, optimisticRequest: nil)
        }
        return Self(
            commands: commands,
            optimisticRequest: RedisOptimisticMutationRequest(
                reference: request.reference,
                assertions: request.assertions,
                operations: request.operations + expiration.map(binaryOperation)
            )
        )
    }

    private static func valuePlan(
        details: RedisKeyDetails,
        stringValue: String,
        rows: [RedisKeyEditableRow],
        expectedElementCount: Int?,
        stringData: RedisBinaryValue?,
        originalStringData: RedisBinaryValue?
    ) throws -> PlanParts {
        let reference = details.reference
        switch reference.type {
        case .string:
            if let stringData, let originalStringData {
                guard stringData != originalStringData else {
                    return PlanParts()
                }
                let source = "SET \(RedisCommandPreviewFormatter.escaped(reference.name)) \(RedisBinaryCommandPreviewFormatter.escaped(stringData)) KEEPTTL"
                let preview = RedisCommandInvocation(
                    source: source,
                    arguments: [
                        "SET", reference.name,
                        RedisBinaryCommandPreviewFormatter.escaped(stringData),
                        "KEEPTTL",
                    ]
                )
                let operation = RedisMutationOperation.command(
                    RedisBinaryCommandInvocation(
                        source: source,
                        arguments: [
                            RedisBinaryValue(utf8: "SET"),
                            RedisBinaryValue(utf8: reference.name),
                            stringData,
                            RedisBinaryValue(utf8: "KEEPTTL"),
                        ]
                    )
                )
                return PlanParts(
                    commands: [preview],
                    request: RedisOptimisticMutationRequest(
                        reference: reference,
                        assertions: [
                            .keyType(.string),
                            .stringValue(originalStringData),
                        ],
                        operations: [operation]
                    )
                )
            }
            guard !details.value.isTruncated else {
                if stringValue != scalarValue(in: details.value) {
                    throw RedisKeyEditError.truncatedString
                }
                return PlanParts()
            }
            guard stringValue != scalarValue(in: details.value) else {
                return PlanParts()
            }
            return PlanParts(commands: [invocation([
                "SET", reference.name, stringValue, "KEEPTTL",
            ])])
        case .list:
            return try listPlan(
                reference: reference,
                rows: rows,
                expectedElementCount: expectedElementCount
            )
        case .hash:
            return try hashPlan(reference: reference, rows: rows)
        case .set:
            return try setPlan(reference: reference, rows: rows)
        case .sortedSet:
            return try sortedSetPlan(reference: reference, rows: rows)
        case .stream, .module, .unknown, .none:
            return PlanParts()
        }
    }

    private static func listPlan(
        reference: RedisKeyReference,
        rows: [RedisKeyEditableRow],
        expectedElementCount: Int?
    ) throws -> PlanParts {
        let changedRows = rows.filter { $0.changeState != .unchanged }
        guard !changedRows.isEmpty else { return PlanParts() }
        var assertions: [RedisMutationAssertion] = [.keyType(.list)]
        if let expectedElementCount {
            assertions.append(.elementCount(expectedElementCount))
        }
        for row in changedRows where !row.isNew {
            guard let index = row.originalIndex else {
                throw RedisKeyEditError.unavailable
            }
            assertions.append(
                .listElement(index: index, value: row.originalSecondData)
            )
        }

        var commands: [RedisCommandInvocation] = []
        var operations: [RedisMutationOperation] = []
        for row in changedRows where !row.isNew && !row.isDeleted
            && row.isSecondValueModified
        {
            guard let index = row.originalIndex else {
                throw RedisKeyEditError.unavailable
            }
            let command = invocation([
                "LSET", reference.name, String(index), row.secondValue,
            ])
            commands.append(command)
            operations.append(.command(binaryInvocation(command)))
        }
        for row in changedRows
            .filter({ !$0.isNew && $0.isDeleted })
            .sorted(by: { ($0.originalIndex ?? 0) > ($1.originalIndex ?? 0) })
        {
            guard let index = row.originalIndex else {
                throw RedisKeyEditError.unavailable
            }
            commands.append(invocation([
                "LSET", reference.name, String(index), "<unique-marker>",
            ]))
            commands.append(invocation([
                "LREM", reference.name, "1", "<unique-marker>",
            ]))
            operations.append(.deleteListElement(
                index: index,
                originalValue: row.originalSecondData
            ))
        }
        let headValues = rows.filter {
            $0.isNew && !$0.isDeleted && $0.insertionEdge == .head
        }.map(\.secondValue)
        let tailValues = rows.filter {
            $0.isNew && !$0.isDeleted && $0.insertionEdge != .head
        }.map(\.secondValue)
        if !headValues.isEmpty {
            let command = invocation(
                ["LPUSH", reference.name] + headValues.reversed()
            )
            commands.append(command)
            operations.append(.command(binaryInvocation(command)))
        }
        if !tailValues.isEmpty {
            let command = invocation(["RPUSH", reference.name] + tailValues)
            commands.append(command)
            operations.append(.command(binaryInvocation(command)))
        }
        return PlanParts(
            commands: commands,
            request: RedisOptimisticMutationRequest(
                reference: reference,
                assertions: assertions,
                operations: operations
            )
        )
    }

    private static func hashPlan(
        reference: RedisKeyReference,
        rows: [RedisKeyEditableRow]
    ) throws -> PlanParts {
        let activeRows = rows.filter { !$0.isDeleted }
        try validateIdentities(activeRows)
        for row in activeRows where !row.thirdValue.isEmpty {
            guard let ttl = Int64(row.thirdValue), ttl > 0 else {
                throw RedisKeyEditError.invalidTTL
            }
        }
        let changedRows = rows.filter { $0.changeState != .unchanged }
        guard !changedRows.isEmpty else { return PlanParts() }
        var assertions: [RedisMutationAssertion] = [.keyType(.hash)]
        var commands: [RedisCommandInvocation] = []
        for row in changedRows {
            if row.isNew {
                assertions.append(.hashValue(
                    field: RedisBinaryValue(utf8: row.firstValue),
                    value: nil
                ))
                commands.append(invocation([
                    "HSET", reference.name, row.firstValue, row.secondValue,
                ]))
                commands.append(contentsOf: hashTTLCommands(
                    reference: reference,
                    row: row
                ))
                continue
            }
            assertions.append(.hashValue(
                field: row.originalFirstData,
                value: row.originalSecondData
            ))
            if row.isDeleted {
                commands.append(invocation([
                    "HDEL", reference.name, row.originalFirstValue,
                ]))
                continue
            }
            if row.isFirstValueModified {
                assertions.append(.hashValue(
                    field: RedisBinaryValue(utf8: row.firstValue),
                    value: nil
                ))
                commands.append(invocation([
                    "HDEL", reference.name, row.originalFirstValue,
                ]))
            }
            if row.isFirstValueModified || row.isSecondValueModified {
                commands.append(invocation([
                    "HSET", reference.name, row.firstValue, row.secondValue,
                ]))
            }
            if row.isFirstValueModified || row.isThirdValueModified {
                commands.append(contentsOf: hashTTLCommands(
                    reference: reference,
                    row: row
                ))
            }
        }
        let deletes = commands.filter { $0.arguments.first == "HDEL" }
        let writes = commands.filter { $0.arguments.first != "HDEL" }
        commands = deletes + writes
        return optimisticPlan(
            reference: reference,
            assertions: assertions,
            commands: commands
        )
    }

    private static func setPlan(
        reference: RedisKeyReference,
        rows: [RedisKeyEditableRow]
    ) throws -> PlanParts {
        let activeRows = rows.filter { !$0.isDeleted }
        try validateIdentities(activeRows)
        let changedRows = rows.filter { $0.changeState != .unchanged }
        guard !changedRows.isEmpty else { return PlanParts() }
        var assertions: [RedisMutationAssertion] = [.keyType(.set)]
        var commands: [RedisCommandInvocation] = []
        for row in changedRows {
            if row.isNew {
                assertions.append(.setMembership(
                    member: RedisBinaryValue(utf8: row.firstValue),
                    exists: false
                ))
                commands.append(invocation([
                    "SADD", reference.name, row.firstValue,
                ]))
                continue
            }
            assertions.append(.setMembership(
                member: row.originalFirstData,
                exists: true
            ))
            if row.isDeleted || row.isFirstValueModified {
                commands.append(invocation([
                    "SREM", reference.name, row.originalFirstValue,
                ]))
            }
            if row.isFirstValueModified {
                assertions.append(.setMembership(
                    member: RedisBinaryValue(utf8: row.firstValue),
                    exists: false
                ))
                commands.append(invocation([
                    "SADD", reference.name, row.firstValue,
                ]))
            }
        }
        return optimisticPlan(
            reference: reference,
            assertions: assertions,
            commands: commands
        )
    }

    private static func sortedSetPlan(
        reference: RedisKeyReference,
        rows: [RedisKeyEditableRow]
    ) throws -> PlanParts {
        let activeRows = rows.filter { !$0.isDeleted }
        try validateIdentities(activeRows)
        for row in activeRows where Double(row.secondValue)?.isNaN != false {
            throw RedisKeyEditError.invalidScore(row.secondValue)
        }
        let changedRows = rows.filter { $0.changeState != .unchanged }
        guard !changedRows.isEmpty else { return PlanParts() }
        var assertions: [RedisMutationAssertion] = [.keyType(.sortedSet)]
        var commands: [RedisCommandInvocation] = []
        for row in changedRows {
            if row.isNew {
                assertions.append(.sortedSetScore(
                    member: RedisBinaryValue(utf8: row.firstValue),
                    score: nil
                ))
                commands.append(invocation([
                    "ZADD", reference.name, row.secondValue, row.firstValue,
                ]))
                continue
            }
            assertions.append(.sortedSetScore(
                member: row.originalFirstData,
                score: row.originalSecondValue
            ))
            if row.isDeleted || row.isFirstValueModified {
                commands.append(invocation([
                    "ZREM", reference.name, row.originalFirstValue,
                ]))
            }
            if !row.isDeleted
                && (row.isFirstValueModified || row.isSecondValueModified)
            {
                if row.isFirstValueModified {
                    assertions.append(.sortedSetScore(
                        member: RedisBinaryValue(utf8: row.firstValue),
                        score: nil
                    ))
                }
                commands.append(invocation([
                    "ZADD", reference.name, row.secondValue, row.firstValue,
                ]))
            }
        }
        return optimisticPlan(
            reference: reference,
            assertions: assertions,
            commands: commands
        )
    }

    private static func optimisticPlan(
        reference: RedisKeyReference,
        assertions: [RedisMutationAssertion],
        commands: [RedisCommandInvocation]
    ) -> PlanParts {
        PlanParts(
            commands: commands,
            request: RedisOptimisticMutationRequest(
                reference: reference,
                assertions: assertions,
                operations: commands.map(binaryOperation)
            )
        )
    }

    private static func hashTTLCommands(
        reference: RedisKeyReference,
        row: RedisKeyEditableRow
    ) -> [RedisCommandInvocation] {
        guard !row.thirdValue.isEmpty else {
            return row.isThirdValueModified
                ? [invocation([
                    "HPERSIST", reference.name, "FIELDS", "1", row.firstValue,
                ])]
                : []
        }
        return [invocation([
            "HPEXPIRE", reference.name, row.thirdValue,
            "FIELDS", "1", row.firstValue,
        ])]
    }

    private static func expirationCommands(
        details: RedisKeyDetails,
        expirationMode: RedisKeyExpirationMode,
        ttlMillisecondsText: String
    ) throws -> [RedisCommandInvocation] {
        let originalMode: RedisKeyExpirationMode = details.ttlMilliseconds == nil
            ? .persistent
            : .expires
        let originalTTL = details.ttlMilliseconds.map(String.init) ?? ""
        let ttlChanged = expirationMode == .expires
            && ttlMillisecondsText != originalTTL
        guard expirationMode != originalMode || ttlChanged else { return [] }
        switch expirationMode {
        case .persistent:
            return [invocation(["PERSIST", details.reference.name])]
        case .expires:
            guard let ttl = Int64(ttlMillisecondsText), ttl > 0 else {
                throw RedisKeyEditError.invalidTTL
            }
            return [invocation([
                "PEXPIRE", details.reference.name, String(ttl),
            ])]
        }
    }

    private static func validateIdentities(
        _ rows: [RedisKeyEditableRow]
    ) throws {
        if rows.contains(where: { $0.isNew && $0.firstValue.isEmpty }) {
            throw RedisKeyEditError.incompleteRow
        }
        var identities = Set<String>()
        for row in rows where !identities.insert(row.firstValue).inserted {
            throw RedisKeyEditError.duplicateIdentity(row.firstValue)
        }
    }

    private static func scalarValue(
        in snapshot: RedisKeyValueSnapshot
    ) -> String {
        snapshot.rows.first?.first ?? ""
    }

    private static func binaryOperation(
        _ invocation: RedisCommandInvocation
    ) -> RedisMutationOperation {
        .command(binaryInvocation(invocation))
    }

    private static func binaryInvocation(
        _ invocation: RedisCommandInvocation
    ) -> RedisBinaryCommandInvocation {
        RedisBinaryCommandInvocation(
            source: invocation.source,
            utf8Arguments: invocation.arguments
        )
    }

    private static func invocation(
        _ arguments: [String]
    ) -> RedisCommandInvocation {
        let invocation = RedisCommandInvocation(source: "", arguments: arguments)
        return RedisCommandInvocation(
            source: RedisCommandPreviewFormatter.source(for: invocation),
            arguments: arguments
        )
    }
}

private struct PlanParts {
    var commands: [RedisCommandInvocation] = []
    var request: RedisOptimisticMutationRequest?
}
