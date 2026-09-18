import Foundation

struct RedisKeyCreationPlan: Equatable, Sendable {
    let reference: RedisKeyReference
    let commands: [RedisCommandInvocation]

    static func make(
        databaseIndex: Int,
        name proposedName: String,
        type: RedisKeyType,
        stringValue: String = "",
        rows: [RedisKeyEditableRow] = [],
        expirationMode: RedisKeyExpirationMode = .persistent,
        ttlMillisecondsText: String = ""
    ) throws -> Self {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RedisKeyEditError.invalidKeyName }
        let reference = RedisKeyReference(
            databaseIndex: databaseIndex,
            name: name,
            type: type
        )
        let write = try writeCommand(
            name: name,
            type: type,
            stringValue: stringValue,
            rows: rows
        )
        return Self(
            reference: reference,
            commands: [write] + (try expirationCommand(
                name: name,
                expirationMode: expirationMode,
                ttlMillisecondsText: ttlMillisecondsText
            ))
        )
    }

    private static func writeCommand(
        name: String,
        type: RedisKeyType,
        stringValue: String,
        rows: [RedisKeyEditableRow]
    ) throws -> RedisCommandInvocation {
        switch type {
        case .string:
            return invocation(["SET", name, stringValue])
        case .hash:
            let activeRows = identityRows(in: rows)
            try validateIdentities(activeRows.map(\.firstValue))
            return invocation(
                ["HSET", name]
                    + activeRows.flatMap { [$0.firstValue, $0.secondValue] }
            )
        case .list:
            let values = rows
                .filter { !$0.isDeleted }
                .map(\.secondValue)
                .filter { !isBlank($0) }
            guard !values.isEmpty else {
                throw RedisKeyEditError.incompleteRow
            }
            return invocation(["RPUSH", name] + values)
        case .set:
            let activeRows = identityRows(in: rows)
            try validateIdentities(activeRows.map(\.firstValue))
            return invocation(["SADD", name] + activeRows.map(\.firstValue))
        case .sortedSet:
            let activeRows = identityRows(in: rows)
            try validateIdentities(activeRows.map(\.firstValue))
            for row in activeRows where Double(row.secondValue)?.isNaN != false
            {
                throw RedisKeyEditError.invalidScore(row.secondValue)
            }
            return invocation(
                ["ZADD", name]
                    + activeRows.flatMap { [$0.secondValue, $0.firstValue] }
            )
        case .stream, .module, .none, .unknown:
            throw RedisKeyEditError.unsupportedType(type)
        }
    }

    private static func expirationCommand(
        name: String,
        expirationMode: RedisKeyExpirationMode,
        ttlMillisecondsText: String
    ) throws -> [RedisCommandInvocation] {
        guard expirationMode == .expires else { return [] }
        guard let ttl = Int64(ttlMillisecondsText), ttl > 0 else {
            throw RedisKeyEditError.invalidTTL
        }
        return [invocation(["PEXPIRE", name, String(ttl)])]
    }

    private static func identityRows(
        in rows: [RedisKeyEditableRow]
    ) -> [RedisKeyEditableRow] {
        rows.filter { row in
            !row.isDeleted && !(isBlank(row.firstValue) && isBlank(row.secondValue))
        }
    }

    private static func validateIdentities(_ identities: [String]) throws {
        guard !identities.isEmpty else {
            throw RedisKeyEditError.incompleteRow
        }
        var seen = Set<String>()
        for identity in identities {
            guard !identity.isEmpty else {
                throw RedisKeyEditError.incompleteRow
            }
            guard seen.insert(identity).inserted else {
                throw RedisKeyEditError.duplicateIdentity(identity)
            }
        }
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
