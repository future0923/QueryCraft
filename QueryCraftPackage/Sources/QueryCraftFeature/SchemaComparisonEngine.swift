import Foundation

struct SchemaComparisonSnapshot: Sendable {
    struct Object: Sendable {
        let name: String
        let ddl: String
        let definition: MySQLSchemaDefinition?
        let error: String?
        var columns: [WorkspaceDatabaseColumn]? = nil
    }

    let database: String
    let serverID: String
    let version: String
    let sqlMode: String
    let lowerCaseTableNames: Int
    let objects: [Object]
    let capturedAt: Date
    var engineMetadata: SchemaEngineJSON? = nil

    var allowsExport: Bool { !objects.contains { $0.error != nil } }
    func matchingKey(_ name: String) -> String {
        lowerCaseTableNames == 0 ? name : name.lowercased()
    }
}

struct SchemaComparisonDifference: Equatable, Identifiable, Sendable {
    enum Status: String, CaseIterable, Sendable {
        case added, modified, targetOnly, equal, unavailable

        var title: String {
            switch self {
            case .added: AppCopy.current.text("源独有", "Source only")
            case .modified: AppCopy.current.text("有变化", "Changed")
            case .targetOnly: AppCopy.current.text("目标独有", "Target only")
            case .equal: AppCopy.current.text("一致", "Equal")
            case .unavailable: AppCopy.current.text("无法完整比较", "Incomplete")
            }
        }
    }

    let id: String
    let table: String
    let object: String
    var status: Status
    let source: String
    let target: String
    let sourceDDL: String
    let targetDDL: String
    let sql: String?
    var explanation: String
    var routineType: String? = nil
    var containerID: String? = nil
    var groupKey: String { containerID ?? "table:" + table }
    var objectName: String? = nil
    var attributes: [SchemaComparisonAttribute] = []
    var reviewSQL: String? = nil
    var requiredIDs: Set<String> = []
    var planOrder = 20
    var isRisky: Bool? = nil
    var sqlForReview: String? { reviewSQL ?? sql }
    var needsDestructiveReview: Bool {
        if let isRisky { return isRisky }
        return status == .targetOnly || object.hasPrefix("column:") && (status == .modified || status == .added && sql == nil)
            || reviewSQL?.localizedCaseInsensitiveContains("DROP ") == true
    }
}

enum SchemaComparisonEngine {
    static func compare(
        source: SchemaComparisonSnapshot, target: SchemaComparisonSnapshot,
        options: SchemaComparisonOptions = .init()
    ) throws -> [SchemaComparisonDifference] {
        if source.serverID == target.serverID,
           source.matchingKey(source.database) == target.matchingKey(target.database) {
            throw SchemaComparisonError.sameDatabase
        }
        let sameRules = source.lowerCaseTableNames == target.lowerCaseTableNames
        // If identifier rules differ, exact matches only, and no export.
        func key(_ name: String) -> String { sameRules ? source.matchingKey(name) : name }
        let sourceObjectsInScope = source.objects.filter { options.includes($0.name, caseInsensitive: source.lowerCaseTableNames != 0) }
        let targetObjectsInScope = target.objects.filter { options.includes($0.name, caseInsensitive: target.lowerCaseTableNames != 0) }
        let sourceByName = Dictionary(grouping: sourceObjectsInScope, by: { key($0.name) })
        let targetByName = Dictionary(grouping: targetObjectsInScope, by: { key($0.name) })
        let compatible = sameRules && MySQLSchemaCompatibility.modesAgree(source.sqlMode, target.sqlMode)
            && MySQLSchemaCompatibility.canExportAdditions(from: source.version, to: target.version)
            && sourceObjectsInScope.allSatisfy { $0.error == nil } && targetObjectsInScope.allSatisfy { $0.error == nil }
        var result: [SchemaComparisonDifference] = []
        for name in Set(sourceByName.keys).union(targetByName.keys).sorted() {
            try Task.checkCancellation()
            let sourceObjects = sourceByName[name] ?? []
            let targetObjects = targetByName[name] ?? []
            let s = sourceObjects.first
            let t = targetObjects.first
            let table = s?.name ?? t?.name ?? name
            func difference(
                _ object: String, _ status: SchemaComparisonDifference.Status,
                _ before: String, _ after: String, sql: String? = nil, reason: String, objectName: String? = nil,
                attributes: [SchemaComparisonAttribute] = []
            ) -> SchemaComparisonDifference {
                .init(id: name + "\u{0}" + object, table: table, object: object,
                      status: status, source: after, target: before,
                      sourceDDL: s?.ddl ?? "", targetDDL: t?.ddl ?? "", sql: sql,
                      explanation: reason, objectName: objectName, attributes: attributes)
            }
            let manual = AppCopy.current.text(
                "此项仅供比较。可导出的变更限于已有表的可空字段和普通索引新增。",
                "Comparison only. SQL export supports nullable-column and simple-index additions on existing tables."
            )
            if sourceObjects.count > 1 || targetObjects.count > 1 || s?.error != nil || t?.error != nil {
                result.append(difference("table", .unavailable, t?.ddl ?? "", s?.ddl ?? "",
                                         reason: s?.error ?? t?.error ?? manual))
                continue
            }
            guard let s, let t else {
                result.append(difference("table", s == nil ? .targetOnly : .added,
                                         t?.ddl ?? "", s?.ddl ?? "", reason: manual))
                continue
            }
            guard let sd = s.definition, let td = t.definition else {
                result.append(difference("table", .unavailable, t.ddl, s.ddl, reason: manual))
                continue
            }
            let sourceParts = Dictionary(uniqueKeysWithValues: sd.parts.map { ($0.key, $0) })
            let targetParts = Dictionary(uniqueKeysWithValues: td.parts.map { ($0.key, $0) })
            func column(_ object: SchemaComparisonSnapshot.Object, _ part: MySQLSchemaDefinition.Part?) -> WorkspaceDatabaseColumn? {
                guard let part, part.kind == .column else { return nil }
                return object.columns?.first { $0.name.caseInsensitiveCompare(part.name) == .orderedSame }
            }
            func attributes(_ sp: MySQLSchemaDefinition.Part?, _ tp: MySQLSchemaDefinition.Part?) -> [SchemaComparisonAttribute] {
                let sc = column(s, sp), tc = column(t, tp)
                if sc != nil || tc != nil {
                    return SchemaComparisonSemantics.columnAttributes(source: sc, target: tc,
                        sourcePart: sp, targetPart: tp, options: options)
                }
                return []
            }
            func definitionsEqual(_ sp: MySQLSchemaDefinition.Part, _ tp: MySQLSchemaDefinition.Part) -> Bool {
                if column(s, sp) != nil && column(t, tp) != nil { return attributes(sp, tp).isEmpty }
                return options.comparableTokens(sp.tokens) == options.comparableTokens(tp.tokens)
            }
            let sameOptions = MySQLSchemaCompatibility.tableOptions(options.comparableTokens(sd.options), version: source.version)
                == MySQLSchemaCompatibility.tableOptions(options.comparableTokens(td.options), version: target.version)
            for partKey in Set(sourceParts.keys).union(targetParts.keys).sorted() {
                let sp = sourceParts[partKey]
                let tp = targetParts[partKey]
                if let kind = (sp ?? tp)?.kind,
                   (kind == .column && !options.columns || kind == .index && !options.indexes || kind == .constraint && !options.constraints) { continue }
                let status: SchemaComparisonDifference.Status = if sp == nil { .targetOnly }
                    else if tp == nil { .added }
                    else if let sp, let tp, definitionsEqual(sp, tp) { .equal }
                    else { .modified }
                var sql: String?
                if let sp, tp == nil, compatible, sameOptions {
                    let qualified = MySQLSchemaDefinition.identifier(target.database)
                        + "." + MySQLSchemaDefinition.identifier(t.name)
                    if MySQLSchemaDefinition.canAddColumn(sp),
                       MySQLSchemaCompatibility.canTransferColumn(sp, from: source.version, to: target.version) {
                        sql = "ALTER TABLE \(qualified) ADD COLUMN \(sp.definition);"
                    } else if let columns = MySQLSchemaDefinition.simpleIndexColumns(sp),
                              !td.parts.contains(where: { $0.indexName?.lowercased() == sp.name.lowercased() }),
                              columns.allSatisfy({ name in
                                  let k = "column:" + name.lowercased()
                                  guard let sp = sourceParts[k], let tp = targetParts[k] else { return false }
                                  return definitionsEqual(sp, tp)
                              }) {
                        sql = "ALTER TABLE \(qualified) ADD \(sp.definition);"
                    }
                }
                let reason: String
                if status == .equal {
                    reason = AppCopy.current.text("定义一致。", "Definitions match.")
                } else if sql != nil {
                    reason = AppCopy.current.text(
                        "仅生成 SQL，不执行。部署前重新核对目标结构、权限及 DDL 锁开销。",
                        "Export only. Recheck target metadata, permissions and DDL lock costs before deployment."
                    )
                } else if !compatible || !sameOptions {
                    reason = AppCopy.current.text(
                        "两端版本、SQL 模式、名称规则或表选项不同，或存在未完整采集的对象；此轮仅对比。",
                        "Version, SQL mode, identifier rules or table options differ, or metadata is incomplete. Comparison only."
                    )
                } else { reason = manual }
                result.append(difference(partKey, status, tp?.definition ?? "", sp?.definition ?? "", sql: sql,
                                         reason: reason, objectName: sp?.name ?? tp?.name, attributes: attributes(sp, tp)))
            }
            if !sameOptions && options.tableOptions {
                result.append(difference("options", .modified, td.options.joined(separator: " "),
                                         sd.options.joined(separator: " "), reason: manual))
            }
        }
        return SchemaComparisonSQLPlanner.plan(result, source: source, target: target, compatible: compatible)
    }
}

/// Uses the existing read-only session contract; no dynamic driver ABI changes.
protocol SchemaComparisonSnapshotLoading: Sendable {
    func load(
        configuration: DatabaseConnectionConfiguration,
        progress: @escaping @Sendable (SchemaComparisonLoadProgress) async -> Void
    ) async throws -> SchemaComparisonSnapshot
}

struct MySQLSchemaSnapshotLoader: SchemaComparisonSnapshotLoading {
    let sessionFactory: any WorkspaceSessionFactory
    var options = SchemaComparisonOptions()

    func load(
        configuration: DatabaseConnectionConfiguration,
        progress: @escaping @Sendable (SchemaComparisonLoadProgress) async -> Void
    ) async throws -> SchemaComparisonSnapshot {
        guard configuration.databaseProduct == .mysql,
              let database = configuration.database, !database.isEmpty else {
            throw SchemaComparisonError.invalidDatabase
        }
        let session = await sessionFactory.makeSession(configuration: configuration)
        do {
            try Task.checkCancellation()
            // Existing drivers publish their client only after connect returns.
            // Do not cancel halfway through that ownership transfer: await the
            // connection attempt, then honor cancellation and close the session.
            // This task is always awaited and deliberately never canceled.
            let connecting = Task { try await session.connect() }
            try await connecting.value
            try Task.checkCancellation()
            let collector = SchemaComparisonScalarCollector()
            _ = try await session.executeReadOnlyQuery(
                "SELECT @@version, @@version_comment, @@server_uuid, @@lower_case_table_names, @@sql_mode",
                database: database
            ) { batch in await collector.append(batch) }
            let values = await collector.values
            guard values.count == 5,
                  MySQLSchemaCompatibility.supportsMetadata(version: values[0], comment: values[1]),
                  !values[2].isEmpty, let caseMode = Int(values[3]), (0...2).contains(caseMode) else {
                throw SchemaComparisonError.unsupportedServer
            }
            let databases = try await session.fetchDatabases()
            guard databases.contains(database) else { throw SchemaComparisonError.invalidDatabase }
            let objects = try await session.fetchObjects(in: database).filter {
                $0.kind == .table && options.includes($0.name, caseInsensitive: caseMode != 0)
            }
            await progress(.init(total: objects.count))
            var snapshots: [SchemaComparisonSnapshot.Object] = []
            for (index, object) in objects.enumerated() {
                try Task.checkCancellation()
                await progress(.init(completed: index, total: objects.count, objectName: object.name))
                var ddl = ""
                do {
                    let details = try await session.fetchDetails(for: object, in: database)
                    try Task.checkCancellation()
                    ddl = details.ddl
                    let definition = try MySQLSchemaDefinition(
                        ddl: ddl, noBackslashEscapes: values[4].split(separator: ",").contains("NO_BACKSLASH_ESCAPES")
                    )
                    snapshots.append(.init(name: object.name, ddl: ddl, definition: definition, error: nil, columns: details.columns))
                } catch is CancellationError { throw CancellationError() }
                catch {
                    snapshots.append(.init(name: object.name, ddl: ddl, definition: nil, error: error.localizedDescription))
                }
                await progress(.init(completed: index + 1, total: objects.count, objectName: object.name))
            }
            try Task.checkCancellation()
            await session.close()
            return SchemaComparisonSnapshot(database: database, serverID: values[2], version: values[0],
                                            sqlMode: values[4], lowerCaseTableNames: caseMode,
                                            objects: snapshots, capturedAt: Date())
        } catch {
            await session.close()
            throw error
        }
    }
}

private actor SchemaComparisonScalarCollector {
    private(set) var values: [String] = []
    func append(_ batch: WorkspaceDatabaseDataBatch) {
        guard values.isEmpty, let row = batch.rows.first else { return }
        values = row.values.map { cell in
            if case let .text(value) = cell { return value }
            return ""
        }
    }
}

/// Metadata support and the narrower, verified additive-DDL compatibility are separate.
enum MySQLSchemaCompatibility {
    static func tableOptions(_ tokens: [String], version: String) -> [String] {
        // SHOW CREATE omits the character set's default collation. Its utf8mb4
        // default changed in MySQL 8; make that implied value explicit without
        // treating genuinely different collations as equal.
        guard !tokens.contains("COLLATE"), let charset = tokens.firstIndex(of: "CHARSET") else { return tokens }
        let value = charset + (tokens.indices.contains(charset + 1) && tokens[charset + 1] == "=" ? 2 : 1)
        guard tokens.indices.contains(value), tokens[value] == "UTF8MB4",
              ["5.7", "8.0", "8.4"].contains(series(version)) else { return tokens }
        var result = tokens
        result.insert(contentsOf: ["COLLATE", "=", series(version) == "5.7" ? "UTF8MB4_GENERAL_CI" : "UTF8MB4_0900_AI_CI"], at: value + 1)
        return result
    }
    private static func series(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }
    static func supportsMetadata(version: String, comment: String) -> Bool {
        ["5.7", "8.0", "8.4"].contains(series(version))
            && !version.localizedCaseInsensitiveContains("mariadb")
            && !comment.localizedCaseInsensitiveContains("mariadb")
    }
    static func canExportAdditions(from source: String, to target: String) -> Bool {
        let supported = ["5.7", "8.0", "8.4"]
        guard let a = supported.firstIndex(of: series(source)),
              let b = supported.firstIndex(of: series(target)) else { return false }
        return a <= b
    }
    static func modesAgree(_ source: String, _ target: String) -> Bool {
        func relevant(_ value: String) -> Set<String> {
            // Removed in MySQL 8; it governs CREATE USER, not table/column DDL.
            Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
                .subtracting(["NO_AUTO_CREATE_USER"])
        }
        return relevant(source) == relevant(target)
    }
    static func canTransferColumn(_ part: MySQLSchemaDefinition.Part, from source: String, to target: String) -> Bool {
        guard series(source) != series(target) else { return true }
        // Legacy floating-point precision syntax differs between releases.
        return !["FLOAT", "DOUBLE"].contains(part.canonical[1])
    }
}
