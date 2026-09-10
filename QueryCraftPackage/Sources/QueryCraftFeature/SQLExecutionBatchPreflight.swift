import Foundation

enum SQLExecutionBatchPreflight {
    static func makePlan(
        target: SQLExecutionTarget,
        parseSnapshot: SQLParseSnapshot
    ) throws -> SQLExecutionBatchPlan {
        guard parseSnapshot.revision == target.source.revision,
              parseSnapshot.sourceLength
                == (target.source.text as NSString).length
        else {
            throw SQLExecutionBatchPreflightError.sourceChanged
        }

        let statements = switch target.kind {
        case .selection:
            selectionStatements(target: target, snapshot: parseSnapshot)
        case .currentStatement:
            try reliableStatements(target: target, snapshot: parseSnapshot)
        case .document:
            documentStatements(target: target, snapshot: parseSnapshot)
        }
        guard !statements.isEmpty else {
            throw SQLExecutionBatchPreflightError.noExecutableStatement
        }
        return SQLExecutionBatchPlan(
            target: target,
            statements: statements
        )
    }

    private static func selectionStatements(
        target: SQLExecutionTarget,
        snapshot: SQLParseSnapshot
    ) -> [SQLExecutionStatement] {
        if let statements = try? reliableStatements(
            target: target,
            snapshot: snapshot
        ) {
            return statements
        }
        if selectionMatchesReadQueryBlock(
            target: target,
            snapshot: snapshot
        ) {
            return [
                SQLExecutionStatement(
                    index: 0,
                    source: target.source,
                    range: target.range,
                    kind: .read
                )
            ]
        }

        return [
            SQLExecutionStatement(
                index: 0,
                source: target.source,
                range: target.range,
                kind: .unknown
            )
        ]
    }

    private static func selectionMatchesReadQueryBlock(
        target: SQLExecutionTarget,
        snapshot: SQLParseSnapshot
    ) -> Bool {
        let selectedPayload = trimmedPayloadRange(
            target.range,
            source: target.source.text
        )
        guard selectedPayload.length > 0 else { return false }

        var pending = snapshot.queryScopes
        while let scope = pending.popLast() {
            pending.append(contentsOf: scope.children)
            guard scope.kind == .queryBlock else { continue }
            if trimmedPayloadRange(
                scope.range,
                source: target.source.text
            ) == selectedPayload {
                return true
            }
        }
        return false
    }

    private static func reliableStatements(
        target: SQLExecutionTarget,
        snapshot: SQLParseSnapshot
    ) throws -> [SQLExecutionStatement] {
        let targetRange = target.range.nsRange
        guard !snapshot.unreliableStatementRanges.contains(where: {
            NSIntersectionRange($0.nsRange, targetRange).length > 0
        }) else {
            throw SQLExecutionBatchPreflightError.unreliableStatement
        }

        let intersectingStatements = snapshot.statements.filter {
            NSIntersectionRange($0.range.nsRange, targetRange).length > 0
        }
        guard !intersectingStatements.isEmpty else {
            throw SQLExecutionBatchPreflightError.noExecutableStatement
        }
        guard intersectingStatements.allSatisfy({ statement in
            let payloadRange = executablePayloadRange(
                for: statement,
                source: target.source.text
            )
            return payloadRange.location >= target.range.location
                && payloadRange.upperBound <= target.range.upperBound
        }) else {
            throw SQLExecutionBatchPreflightError.partialStatement
        }

        return intersectingStatements.enumerated().map { index, statement in
            let range = target.kind == .selection
                ? SQLSourceRange(
                    NSIntersectionRange(statement.range.nsRange, targetRange)
                )
                : statement.range
            return SQLExecutionStatement(
                index: index,
                source: target.source,
                range: range,
                kind: statement.kind
            )
        }
    }

    private static func documentStatements(
        target: SQLExecutionTarget,
        snapshot: SQLParseSnapshot
    ) -> [SQLExecutionStatement] {
        let targetRange = target.range.nsRange
        let reliable: [(range: SQLSourceRange, kind: SQLStatementKind)] =
            snapshot.statements.compactMap { statement in
            guard NSIntersectionRange(statement.range.nsRange, targetRange).length > 0
            else {
                return nil
            }
            return (range: statement.range, kind: statement.kind)
        }
        let unresolved: [(range: SQLSourceRange, kind: SQLStatementKind)] =
            snapshot.unreliableStatementRanges.compactMap { range in
            let intersection = NSIntersectionRange(range.nsRange, targetRange)
            guard intersection.length > 0 else { return nil }
            return (range: SQLSourceRange(intersection), kind: SQLStatementKind.unknown)
        }
        return (reliable + unresolved)
            .sorted { $0.range.location < $1.range.location }
            .enumerated()
            .map { index, statement in
                SQLExecutionStatement(
                    index: index,
                    source: target.source,
                    range: statement.range,
                    kind: statement.kind
                )
            }
    }

    private static func executablePayloadRange(
        for statement: SQLStatement,
        source: String
    ) -> SQLSourceRange {
        trimmedPayloadRange(statement.range, source: source)
    }

    private static func trimmedPayloadRange(
        _ range: SQLSourceRange,
        source: String
    ) -> SQLSourceRange {
        let text = (source as NSString).substring(with: range.nsRange)
        var payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingOffset = (text as NSString).range(of: payload).location
        if payload.hasSuffix(";") {
            payload.removeLast()
            payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return SQLSourceRange(
            location: range.location + leadingOffset,
            length: (payload as NSString).length
        )
    }
}

enum SQLExecutionBatchPreflightError: LocalizedError, Equatable {
    case sourceChanged
    case noExecutableStatement
    case unreliableStatement
    case partialStatement

    var errorDescription: String? {
        switch self {
        case .sourceChanged:
            AppCopy.current.text(
                "批量预检完成前 SQL 已发生变化。",
                "The SQL changed before batch preflight completed."
            )
        case .noExecutableStatement:
            AppCopy.current.text(
                "执行目标中未找到可可靠执行的 SQL 语句。",
                "No reliable SQL statement was found in the execution target."
            )
        case .unreliableStatement:
            AppCopy.current.text(
                "批处理中包含无法可靠确定边界的 SQL。",
                "The batch contains SQL whose boundaries cannot be determined reliably."
            )
        case .partialStatement:
            AppCopy.current.text(
                "所选范围截断了 SQL 语句，请选择完整语句。",
                "The selection cuts through a SQL statement. Select complete statements."
            )
        }
    }
}
