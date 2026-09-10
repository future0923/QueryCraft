import Foundation

@MainActor
enum RedisKeyCommandExporter {
    static func wholeKey(
        details: RedisKeyDetails,
        editor: RedisKeyEditorState
    ) -> String? {
        let commands: [[RedisBinaryValue]]
        switch details.reference.type {
        case .string:
            guard editor.isStringFullyLoaded else { return nil }
            commands = [[
                value("SET"), value(details.reference.name), editor.stringData,
            ]]
        case .list:
            guard editor.isCollectionFullyLoaded else { return nil }
            commands = collectionCommands(
                details: details,
                rows: activeRows(editor.rows)
            )
        case .hash, .set, .sortedSet:
            guard editor.isCollectionFullyLoaded else { return nil }
            commands = collectionCommands(
                details: details,
                rows: activeRows(editor.rows)
            )
        case .stream, .module, .unknown, .none:
            return nil
        }
        return render(commands + expirationCommand(for: details))
    }

    static func selectedRows(
        details: RedisKeyDetails,
        editor: RedisKeyEditorState
    ) -> String? {
        guard details.reference.type != .string else { return nil }
        return render(collectionCommands(
            details: details,
            rows: editor.selectedRows
        ))
    }

    private static func collectionCommands(
        details: RedisKeyDetails,
        rows: [RedisKeyEditableRow]
    ) -> [[RedisBinaryValue]] {
        guard !rows.isEmpty else { return [] }
        let key = value(details.reference.name)
        switch details.reference.type {
        case .list:
            return [[value("RPUSH"), key] + rows.map(secondValue)]
        case .hash:
            var command = [value("HSET"), key]
            for row in rows {
                command.append(firstValue(row))
                command.append(secondValue(row))
            }
            var commands = [command]
            for row in rows where !row.thirdValue.isEmpty {
                commands.append([
                    value("HPEXPIRE"), key, value(row.thirdValue),
                    value("FIELDS"), value("1"), firstValue(row),
                ])
            }
            return commands
        case .set:
            return [[value("SADD"), key] + rows.map(firstValue)]
        case .sortedSet:
            var command = [value("ZADD"), key]
            for row in rows {
                command.append(value(row.secondValue))
                command.append(firstValue(row))
            }
            return [command]
        case .string, .stream, .module, .unknown, .none:
            return []
        }
    }

    private static func expirationCommand(
        for details: RedisKeyDetails
    ) -> [[RedisBinaryValue]] {
        guard let ttl = details.ttlMilliseconds, ttl > 0 else { return [] }
        return [[
            value("PEXPIRE"), value(details.reference.name), value(String(ttl)),
        ]]
    }

    private static func activeRows(
        _ rows: [RedisKeyEditableRow]
    ) -> [RedisKeyEditableRow] {
        rows.filter { !$0.isDeleted }
    }

    private static func firstValue(
        _ row: RedisKeyEditableRow
    ) -> RedisBinaryValue {
        row.isNew || row.isFirstValueModified
            ? value(row.firstValue)
            : row.originalFirstData
    }

    private static func secondValue(
        _ row: RedisKeyEditableRow
    ) -> RedisBinaryValue {
        row.isNew || row.isSecondValueModified
            ? value(row.secondValue)
            : row.originalSecondData
    }

    private static func render(_ commands: [[RedisBinaryValue]]) -> String? {
        guard !commands.isEmpty else { return nil }
        return commands.map { command in
            command.map(RedisBinaryCommandPreviewFormatter.escaped)
                .joined(separator: " ")
        }.joined(separator: "\n")
    }

    private static func value(_ string: String) -> RedisBinaryValue {
        RedisBinaryValue(utf8: string)
    }
}
