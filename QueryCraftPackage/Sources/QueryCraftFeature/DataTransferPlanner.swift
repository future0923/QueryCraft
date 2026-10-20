import Foundation

struct TransferForeignKey: Sendable, Equatable {
    let table: String
    let referencedTable: String
    let sql: String
}

struct TransferPlanItem: Sendable {
    let object: TransferObject
    let targetName: String
    let existed: Bool
    let sourceColumns: [WorkspaceDatabaseColumn]
    let targetColumns: [WorkspaceDatabaseColumn]
    let statements: [String]
    let primaryKey: [String]
    let backupName: String?
    var dependencies: [String] = []
    var foreignKeys: [TransferForeignKey] = []
}

enum TransferOwnership: String, CaseIterable, Identifiable, Sendable {
    case preserve, skip, reassignMissing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .preserve: AppCopy.current.text("保留所有者", "Preserve owners")
        case .skip: AppCopy.current.text("跳过所有者", "Skip ownership")
        case .reassignMissing: AppCopy.current.text("缺失所有者使用目标当前用户", "Assign missing owners to target user")
        }
    }
}

struct DataTransferPlan: Sendable {
    let id: UUID
    let configuration: DataTransferConfiguration
    let source: TransferConnection
    let target: TransferConnection
    var items: [TransferPlanItem]
    var warnings: [String]
    var missingOwners: [String] = []
    var ownershipStatements: [String] = []
    var ownership = TransferOwnership.preserve
    var setupStatements: [String] = []
    var sourceServerIdentity = ""
    var targetServerIdentity = ""
    var mysqlNoBackslashEscapes: Bool? = nil
    var sql: String {
        var statements = setupStatements.map { $0 + ";" }
        for item in items where item.backupName != nil {
            if let backup = item.backupName {
                let original = TransferSQL.qualified(target.endpoint, item.targetName, type: target.type)
                statements.append(target.type == .mysql
                    ? "RENAME TABLE \(original) TO \(TransferSQL.qualified(target.endpoint, backup, type: target.type));"
                    : "ALTER TABLE \(original) RENAME TO \(TransferSQL.dialect(target.type).identifier(backup));")
            }
        }
        for item in items where item.object.kind.order <= TransferObjectKind.table.order {
            statements.append(mappingComment(item))
            statements.append(contentsOf: item.statements.map { $0 + ";" })
        }
        if configuration.content != .structureOnly {
            let tables = items.filter { $0.object.kind == .table }
            for item in tables {
                if configuration.strategy == .overwrite && item.existed {
                    statements.append("DELETE FROM \(TransferSQL.qualified(target.endpoint, item.targetName, type: target.type));")
                }
            }
            if !tables.isEmpty {
                statements.append("-- " + AppCopy.current.text("以上 \(tables.count) 张表采用「\(configuration.strategy.title)」方式传输，每批 \(configuration.batchSize) 行。", "Transfer the \(tables.count) tables above using \(configuration.strategy.title), in batches of \(configuration.batchSize) rows."))
            }
        }
        statements.append(contentsOf: items.flatMap(\.foreignKeys).map { $0.sql + ";" })
        for item in items where item.object.kind.order > TransferObjectKind.table.order {
            statements.append(mappingComment(item))
            statements.append(contentsOf: item.statements.map { $0 + ";" })
        }
        statements.append(contentsOf: ownershipStatements.map { $0 + ";" })
        if items.contains(where: { $0.backupName != nil }) {
            statements.append("-- " + AppCopy.current.text("仅在全部表、约束和对象成功后清理原表备份", "Clean original-table backups only after all tables, constraints and objects succeed"))
            statements.append(contentsOf: items.reversed().compactMap { $0.backupName }.map { "DROP TABLE \(TransferSQL.qualified(target.endpoint, $0, type: target.type));" })
        }
        return statements.joined(separator: "\n\n")
    }

    private func mappingComment(_ item: TransferPlanItem) -> String {
        let original = TransferSQL.previewQualified(source.endpoint, item.object.name, type: source.type)
        let destination = TransferSQL.previewQualified(target.endpoint, item.targetName, type: target.type)
        return "-- \(item.object.kind.title): \(original) → \(destination)"
    }
}

struct DataTransferPlanner: Sendable {
    let catalog: DataTransferCatalog
    init(catalog: DataTransferCatalog = .init()) { self.catalog = catalog }

    func prepare(configuration: DataTransferConfiguration, source: TransferConnection, target: TransferConnection,
                 ownership: TransferOwnership = .preserve, id: UUID = UUID()) async throws -> DataTransferPlan {
        try configuration.validate(sourceType: source.type, targetType: target.type)
        guard !(source.configuration.host.lowercased() == target.configuration.host.lowercased()
                && source.configuration.port == target.configuration.port && source.type == target.type
                && source.endpoint.database == target.endpoint.database && source.endpoint.namespace == target.endpoint.namespace) else {
            throw TransferFailure("源和目标指向同一服务器位置，已停止传输。", "Source and target refer to the same server location. Transfer stopped.")
        }
        let read = try await catalog.open(source)
        var write: (any WorkspaceSession)?
        do {
            let connected = try await catalog.open(target); write = connected
            guard connected.resolvedCapabilities.supportsTransactions && connected.resolvedCapabilities.supportsDataEditing else {
                throw TransferFailure("目标驱动不支持事务写入。", "The target driver does not support transactional writes.")
            }
            let available = try await DataTransferCatalog.objects(source, session: read)
            let targetObjects = try await DataTransferCatalog.objects(target, session: connected)
            let tableMapping = Dictionary(uniqueKeysWithValues: configuration.objects.filter { $0.kind == .table }.map { ($0.name, configuration.nameCase.apply($0.name)) })
            var plan = DataTransferPlan(id: id, configuration: configuration, source: source, target: target, items: [], warnings: [], ownership: ownership)
            plan.targetServerIdentity = try await DataTransferCatalog.serverIdentity(target, session: connected)
            if target.type == .mysql {
                plan.mysqlNoBackslashEscapes = true
                if source.type == .mysql {
                    let mode = try await DataTransferCatalog.query("SELECT @@SESSION.sql_mode AS mode", session: read, database: source.endpoint.database)
                    guard let row = mode.rows.first, let value = mode.text(row, "mode") else { throw TransferFailure("无法读取来源 SQL 模式。", "Cannot read the source SQL mode.") }
                    plan.mysqlNoBackslashEscapes = value.uppercased().components(separatedBy: ",").contains("NO_BACKSLASH_ESCAPES")
                }
            }
            if source.type == target.type {
                plan.sourceServerIdentity = try await DataTransferCatalog.serverIdentity(source, session: read)
                guard !(plan.sourceServerIdentity == plan.targetServerIdentity
                        && source.endpoint.database == target.endpoint.database && source.endpoint.namespace == target.endpoint.namespace) else {
                    throw TransferFailure("不同连接指向同一数据库位置，已停止传输。", "The connections refer to the same database location. Transfer stopped.")
                }
            }
            var plannedTypes: Set<String> = []
            if source.type == .doris {
                plan.warnings.append(AppCopy.current.text("Doris 来源没有事务快照；传输期间请保持来源静止。聚合状态及复杂类型会明确拒绝。", "Doris has no transactional snapshot. Keep the source quiescent during transfer. Opaque aggregate and complex types are rejected."))
            }
            if configuration.content != .dataOnly && source.type == .postgresql {
                plan.warnings.append(AppCopy.current.text("本次不迁移对象授权、RLS 策略、扩展和任意跨 Schema 依赖；请在目标另行配置。", "Object grants, RLS policies, extensions and arbitrary cross-schema dependencies are not migrated; configure them separately on the target."))
            }
            if configuration.objects.contains(where: { [.function, .procedure, .trigger, .event].contains($0.kind) }) {
                plan.warnings.append(AppCopy.current.text("例程、触发器和事件中的动态 SQL 与字符串体不会自动改写；跨命名空间引用须检查 SQL 预览。对象权限、扩展和策略不属于本次传输。", "Dynamic SQL and string bodies in routines, triggers and events are not rewritten. Review namespace references in SQL preview. Grants, extensions and policies are outside this transfer."))
            }
            for object in configuration.objects {
                try Task.checkCancellation()
                guard available.contains(object) else { throw TransferFailure("来源对象已变化，请重新选择：\(object.name)。", "The source object changed. Select it again: \(object.name).") }
                let targetName = object.kind == .table ? configuration.nameCase.apply(object.name) : object.name
                let targetArgumentTypes = try TransferSQL.rewriteQualified(object.argumentTypes, sourceNamespace: source.endpoint.namespace, targetNamespace: target.endpoint.namespace, tableNames: [:], type: target.type)
                let targetArgumentTokens = try TransferSQL.tokens(targetArgumentTypes).map(\.value)
                guard target.type != .postgresql || targetName.utf8.count <= 63,
                      target.type != .mysql || targetName.count <= 64 else {
                    throw TransferFailure("目标对象名称超过数据库长度限制：\(targetName)。", "The target object name exceeds the database identifier limit: \(targetName).")
                }
                var existing = targetObjects.first {
                    $0.kind == object.kind && $0.name == targetName
                        && (object.kind != .trigger || $0.parentTable == object.parentTable.map { tableMapping[$0] ?? $0 })
                        && (![.function, .procedure].contains(object.kind) || (try? TransferSQL.tokens($0.argumentTypes).map(\.value)) == targetArgumentTokens)
                }
                if object.kind == .trigger && target.type == .postgresql && configuration.strategy == .rebuild,
                   let parent = object.parentTable, let mapped = tableMapping[parent], targetObjects.contains(where: { $0.kind == .table && $0.name == mapped }) {
                    // PostgreSQL trigger names are local to their table. The existing
                    // trigger follows the original table into its backup; create a
                    // new one on the rebuilt table without touching that backup.
                    existing = nil
                }
                if object.kind == .table, targetObjects.contains(where: { $0.name == targetName && $0.kind != .table }) {
                    throw TransferFailure("目标名称已被其他类型对象占用：\(targetName)。", "The target name is used by another object kind: \(targetName).")
                }
                if object.kind != .table {
                    if existing != nil && configuration.strategy == .append {
                        plan.items.append(.init(object: object, targetName: targetName, existed: true, sourceColumns: [], targetColumns: [], statements: [], primaryKey: [], backupName: nil)); continue
                    }
                    var replacement: [String] = []
                    if object.kind == .trigger && target.type == .mysql && configuration.strategy == .rebuild && existing != nil,
                       let parent = object.parentTable, tableMapping[parent] != nil {
                        throw TransferFailure("重建表时，同名 MySQL 触发器仍属于原表备份。请先分别处理触发器，避免破坏备份：\(object.name)。", "During rebuild the same-named MySQL trigger belongs to the original-table backup. Transfer triggers separately to preserve that backup: \(object.name).")
                    }
                    // Never use CASCADE: dependencies outside the selection must remain protected.
                    if existing != nil {
                        let qualified = TransferSQL.qualified(target.endpoint, targetName, type: target.type)
                        let keyword = object.kind == .materializedView ? "MATERIALIZED VIEW" : object.kind.rawValue.uppercased()
                        if target.type == .mysql || [.materializedView, .trigger].contains(object.kind) {
                            let parent = object.kind == .trigger && target.type == .postgresql ? " ON \(TransferSQL.qualified(target.endpoint, tableMapping[object.parentTable ?? ""] ?? object.parentTable ?? "", type: target.type))" : ""
                            replacement.append("DROP \(keyword) \(qualified)\(parent)")
                        }
                    }
                    var ddl = try await DataTransferCatalog.showCreate(object, connection: source, session: read)
                    ddl = try TransferSQL.rewriteQualified(ddl, sourceNamespace: source.endpoint.namespace, targetNamespace: target.endpoint.namespace, tableNames: tableMapping, type: target.type)
                    if object.kind == .trigger, let parent = object.parentTable {
                        ddl = try TransferSQL.retargetCreate(ddl, keyword: "ON", target: TransferSQL.qualified(target.endpoint, tableMapping[parent] ?? parent, type: target.type))
                    }
                    if object.kind == .view || object.kind == .materializedView {
                        if source.type == .postgresql {
                            let command = object.kind == .materializedView ? "CREATE MATERIALIZED VIEW" : existing != nil ? "CREATE OR REPLACE VIEW" : "CREATE VIEW"
                            var optionSQL = "", checkSQL = ""
                            if let oid = UInt64(object.identity) {
                                let options = try await DataTransferCatalog.query("SELECT option_name AS name,option_value AS value FROM pg_options_to_table((SELECT reloptions FROM pg_class WHERE oid=\(oid)))", session: read, database: source.endpoint.database)
                                var clauses: [String] = []
                                for row in options.rows {
                                    guard let name = options.text(row, "name"), let value = options.text(row, "value") else { continue }
                                    if name == "check_option" {
                                        guard ["local", "cascaded"].contains(value.lowercased()) else { throw TransferFailure("未知视图检查选项。", "Unknown view check option.") }
                                        checkSQL = " WITH \(value.uppercased()) CHECK OPTION"
                                    } else {
                                        clauses.append("\(TransferSQL.dialect(.postgresql).identifier(name)) = \(try TransferSQL.string(value, type: .postgresql))")
                                    }
                                }
                                if !clauses.isEmpty { optionSQL = " WITH (" + clauses.joined(separator: ", ") + ")" }
                            }
                            ddl = "\(command) \(TransferSQL.qualified(target.endpoint, targetName, type: target.type))\(optionSQL) AS " + ddl.trimmingCharacters(in: CharacterSet(charactersIn: "; \n\r")) + checkSQL
                            if object.kind == .materializedView { ddl += configuration.content == .structureOnly ? " WITH NO DATA" : " WITH DATA" }
                        } else { ddl = try TransferSQL.retargetCreate(ddl, keyword: "VIEW", target: TransferSQL.qualified(target.endpoint, targetName, type: target.type)) }
                    } else if source.endpoint.namespace != target.endpoint.namespace && [.function, .procedure, .event].contains(object.kind) {
                        // A quoted function body can retain source references even after header rewriting.
                        let suspicious = [source.endpoint.namespace + ".", "\"\(source.endpoint.namespace)\".", "`\(source.endpoint.namespace)`."]
                        guard !suspicious.contains(where: { ddl.contains($0) }) else {
                            throw TransferFailure("例程体仍引用来源命名空间，请先调整来源或保持相同 Schema：\(object.name)。", "The routine body still references the source namespace. Adjust it or retain the schema: \(object.name).")
                        }
                    }
                    if object.kind == .sequence && existing != nil { ddl = ddl.replacingOccurrences(of: "CREATE SEQUENCE", with: "ALTER SEQUENCE", range: ddl.range(of: "CREATE SEQUENCE")) }
                    var dependencies: [String] = []
                    if source.type == .postgresql, [.view, .materializedView].contains(object.kind), let oid = UInt64(object.identity) {
                        let links = try await DataTransferCatalog.query("SELECT DISTINCT c.relname AS name FROM pg_rewrite r JOIN pg_depend d ON d.classid='pg_rewrite'::regclass AND d.objid=r.oid JOIN pg_class c ON c.oid=d.refobjid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE r.ev_class=\(oid) AND d.refclassid='pg_class'::regclass AND n.nspname=\(try TransferSQL.string(source.endpoint.namespace, type: source.type)) AND c.oid<>\(oid)", session: read, database: source.endpoint.database)
                        dependencies = links.rows.compactMap { links.text($0, "name") }
                    } else if object.kind == .trigger { dependencies = object.parentTable.map { [$0] } ?? [] }
                    if object.kind == .sequence, source.type == .postgresql, configuration.content != .structureOnly {
                        let state = try await DataTransferCatalog.query("SELECT last_value::text AS value,is_called::text AS called FROM \(TransferSQL.qualified(source.endpoint, object.name, type: .postgresql))", session: read, database: source.endpoint.database)
                        guard let row = state.rows.first, let value = state.text(row, "value"), Int64(value) != nil else { throw TransferFailure("无法读取序列当前位置。", "Cannot read the current sequence value.") }
                        replacement.append(ddl)
                        ddl = "SELECT setval(\(try TransferSQL.string(TransferSQL.qualified(target.endpoint, targetName, type: .postgresql), type: .postgresql))::regclass,\(value),\(state.text(row, "called") == "true" || state.text(row, "called") == "t" ? "true" : "false"))"
                    }
                    plan.items.append(.init(object: object, targetName: targetName, existed: existing != nil, sourceColumns: [], targetColumns: [], statements: replacement + [ddl], primaryKey: [], backupName: nil, dependencies: dependencies))
                    continue
                }
                let columns = try await DataTransferCatalog.columns(object, connection: source, session: read)
                guard !columns.isEmpty else { throw TransferFailure("无法读取表字段：\(object.name)。", "Cannot read table columns: \(object.name).") }
                if target.type == .postgresql && columns.contains(where: { $0.name.utf8.count > 63 }) { throw TransferFailure("字段名超过 PostgreSQL 的 63 字节限制。", "A column name exceeds PostgreSQL's 63-byte limit.") }
                let create = configuration.content != .dataOnly && (existing == nil || configuration.strategy == .rebuild)
                if create && source.type == .postgresql, let oid = UInt64(object.identity) {
                    let shape = try await DataTransferCatalog.query("SELECT c.relkind::text AS kind,c.relispartition::text AS partition,EXISTS(SELECT 1 FROM pg_inherits i WHERE i.inhrelid=c.oid OR i.inhparent=c.oid)::text AS inheritance FROM pg_class c WHERE c.oid=\(oid)", session: read, database: source.endpoint.database)
                    if let row = shape.rows.first, shape.text(row, "kind") == "p" || shape.text(row, "partition") == "true" || shape.text(row, "inheritance") == "true" {
                        throw TransferFailure("分区或继承表需要专用结构规划，请先准备目标结构并使用仅数据模式：\(object.name)。", "Partitioned or inherited tables require dedicated structure planning. Prepare the target structure and use data-only mode: \(object.name).")
                    }
                }
                if configuration.content == .dataOnly && source.type == .postgresql, let oid = UInt64(object.identity) {
                    let ancestors = try await DataTransferCatalog.query("WITH RECURSIVE ancestors(oid) AS (SELECT inhparent FROM pg_inherits WHERE inhrelid=\(oid) UNION SELECT i.inhparent FROM pg_inherits i JOIN ancestors a ON i.inhrelid=a.oid) SELECT c.relname AS name,n.nspname AS namespace FROM ancestors a JOIN pg_class c ON c.oid=a.oid JOIN pg_namespace n ON n.oid=c.relnamespace", session: read, database: source.endpoint.database)
                    let selected = Set(configuration.objects.filter { $0.kind == .table }.map(\.name))
                    if ancestors.rows.contains(where: { row in ancestors.text(row, "namespace") == source.endpoint.namespace && ancestors.text(row, "name").map(selected.contains) == true }) {
                        throw TransferFailure("同一任务不能同时选择父表和子分区；读取父表已包含子表数据。", "Do not select both a parent table and its partitions in one task; parent reads already include child rows.")
                    }
                }
                guard create || existing != nil else { throw TransferFailure("仅数据模式需要已有目标表：\(targetName)。", "Data-only mode requires an existing target table: \(targetName).") }
                let backup = existing != nil && configuration.strategy == .rebuild ? "__qc_bak_\(id.uuidString.prefix(8))_\(plan.items.count)" : nil
                if let backup, targetObjects.contains(where: { $0.name == backup }) { throw TransferFailure("备份表名称已存在，请重新生成计划。", "A backup table name already exists. Generate a new plan.") }
                let targetColumns: [WorkspaceDatabaseColumn]
                if create {
                    if source.type == .postgresql && target.type == .postgresql {
                        let setup = try await Self.postgresTypes(object, source: source, target: target, sourceSession: read, targetSession: connected, planned: &plannedTypes)
                        plan.setupStatements.append(contentsOf: setup)
                        targetColumns = try columns.map { column in
                            let rewrite: (String) throws -> String = { try TransferSQL.rewriteQualified($0, sourceNamespace: source.endpoint.namespace, targetNamespace: target.endpoint.namespace, tableNames: tableMapping, type: .postgresql) }
                            return .init(name: column.name, type: try rewrite(column.type), collation: column.collation, isNullable: column.isNullable, key: column.key, defaultValue: try column.defaultValue.map(rewrite), extra: column.extra, comment: column.comment, generationExpression: try rewrite(column.generationExpression))
                        }
                    } else { targetColumns = try columns.map { try Self.convertColumn($0, source: source.type, target: target.type) } }
                }
                else { targetColumns = try await DataTransferCatalog.columns(.init(kind: .table, name: targetName), connection: target, session: connected) }
                if !create && configuration.content != .structureOnly {
                    try await DataTransferCatalog.requireTransactionalTable(targetName, connection: target, session: connected)
                    try Self.validateColumns(source: columns, target: targetColumns, sourceType: source.type, targetType: target.type)
                }
                var statements: [String] = [], foreignKeys: [TransferForeignKey] = [], dependencies: [String] = []
                if create {
                    if source.type == .mysql && target.type == .mysql {
                        let raw = try await DataTransferCatalog.showCreate(object, connection: source, session: read)
                        let split = try Self.splitMySQLForeignKeys(raw)
                        var ddl = try TransferSQL.retargetCreate(split.ddl, keyword: "TABLE", target: TransferSQL.qualified(target.endpoint, targetName, type: target.type))
                        ddl = try TransferSQL.rewriteQualified(ddl, sourceNamespace: source.endpoint.namespace, targetNamespace: target.endpoint.namespace, tableNames: tableMapping, type: target.type)
                        guard !ddl.uppercased().contains("ENGINE=MYISAM"), !ddl.uppercased().contains("ENGINE=MEMORY") else { throw TransferFailure("目标只支持 InnoDB 事务表。", "Only InnoDB transactional target tables are supported.") }
                        statements.append(ddl)
                        for (index, key) in split.keys.enumerated() {
                            let name = "qc_\(id.uuidString.prefix(8))_\(plan.items.count)_\(index)"
                            let rewritten = try Self.rewriteForeignKey(key, target: target, source: source, tableMapping: tableMapping, constraintName: name)
                            let referenced = try Self.referencedTable(key)
                            dependencies.append(referenced)
                            foreignKeys.append(.init(table: targetName, referencedTable: tableMapping[referenced] ?? referenced, sql: "ALTER TABLE \(TransferSQL.qualified(target.endpoint, targetName, type: target.type)) ADD \(rewritten)"))
                        }
                    } else {
                        statements.append(try Self.createTable(columns: targetColumns, name: targetName, connection: target))
                        if source.type == .postgresql && target.type == .postgresql {
                            let metadata = try await Self.postgresConstraints(object, source: source, target: target, session: read, mapping: tableMapping, id: id, itemIndex: plan.items.count)
                            statements.append(contentsOf: metadata.statements); foreignKeys = metadata.keys; dependencies = metadata.dependencies
                            if let oid = UInt64(object.identity) {
                                let comments = try await DataTransferCatalog.query("SELECT obj_description(\(oid),'pg_class') AS comment", session: read, database: source.endpoint.database)
                                if let row = comments.rows.first, let comment = comments.text(row, "comment"), !comment.isEmpty {
                                    statements.append("COMMENT ON TABLE \(TransferSQL.qualified(target.endpoint, targetName, type: .postgresql)) IS \(try TransferSQL.string(comment, type: .postgresql))")
                                }
                            }
                        } else {
                            let keys = targetColumns.filter { $0.key == "PRI" }.map(\.name)
                            if !keys.isEmpty && target.type == .postgresql { statements.append("ALTER TABLE \(TransferSQL.qualified(target.endpoint, targetName, type: target.type)) ADD PRIMARY KEY (\(keys.map(TransferSQL.dialect(target.type).identifier).joined(separator: ", ")))") }
                            plan.warnings.append(AppCopy.current.text("跨引擎表 \(object.name)：字段、主键和注释按元数据转换；外键、非主键索引、表选项与依赖对象不自动翻译。", "Cross-engine table \(object.name): columns, primary key and comments are converted from metadata; foreign keys, secondary indexes, table options and dependent objects are not automatically translated."))
                        }
                        statements.append(contentsOf: try Self.comments(columns: targetColumns, name: targetName, connection: target))
                    }
                }
                if !create {
                    // Existing FKs drive insert ordering even when no CREATE is planned.
                    dependencies = try await Self.tableDependencies(object.name, connection: source, session: read)
                }
                let writable = columns.filter { !$0.isGenerated }
                let opaqueDorisTypes = ["hll", "bitmap", "agg_state", "array", "map", "struct"]
                if source.type == .doris && configuration.content != .structureOnly,
                   columns.contains(where: { column in opaqueDorisTypes.contains { column.type.lowercased().hasPrefix($0) } }) {
                    throw TransferFailure("Doris 聚合状态或复杂类型不能直接传输：\(object.name)。", "Doris aggregate-state or complex columns cannot be transferred directly: \(object.name).")
                }
                let keys = targetColumns.filter { $0.key == "PRI" }.map(\.name)
                if configuration.strategy == .upsert && !keys.allSatisfy({ key in writable.contains { $0.name == key } }) || configuration.strategy == .upsert && keys.isEmpty {
                    throw TransferFailure("Upsert 需要来源包含完整目标主键：\(targetName)。", "Upsert requires all target primary-key columns in the source: \(targetName).")
                }
                plan.items.append(.init(object: object, targetName: targetName, existed: existing != nil, sourceColumns: columns, targetColumns: targetColumns, statements: statements, primaryKey: keys, backupName: backup, dependencies: dependencies, foreignKeys: foreignKeys))
            }
            plan.items = try Self.order(plan.items)
            if configuration.content != .dataOnly && source.type == .postgresql && target.type == .postgresql {
                try await Self.addOwnership(to: &plan, sourceSession: read, targetSession: connected)
            }
            await read.close(); await connected.close()
            return plan
        } catch { await read.close(); await write?.close(); throw error }
    }

    static func validateColumns(source: [WorkspaceDatabaseColumn], target: [WorkspaceDatabaseColumn], sourceType: DatabaseType, targetType: DatabaseType) throws {
        let writable = source.filter { !$0.isGenerated }, byName = Dictionary(uniqueKeysWithValues: target.map { ($0.name, $0) })
        for column in writable {
            guard let destination = byName[column.name], !destination.isGenerated else { throw TransferFailure("目标字段不存在或不可写：\(column.name)。", "Target column is missing or not writable: \(column.name).") }
            if TransferSQL.isBinary(column.type, databaseType: sourceType) != TransferSQL.isBinary(destination.type, databaseType: targetType) { throw TransferFailure("二进制字段类型不兼容：\(column.name)。", "Incompatible binary column type: \(column.name).") }
        }
        for column in target where !column.isGenerated && !column.isNullable && column.defaultValue == nil && !column.extra.uppercased().contains("IDENTITY") && !column.extra.lowercased().contains("auto_increment") {
            guard writable.contains(where: { $0.name == column.name }) else { throw TransferFailure("目标必填字段没有来源：\(column.name)。", "Required target column has no source: \(column.name).") }
        }
    }

    static func convertColumn(_ column: WorkspaceDatabaseColumn, source: DatabaseType, target: DatabaseType) throws -> WorkspaceDatabaseColumn {
        if source == target { return column }
        guard !column.isGenerated else { throw TransferFailure("跨引擎生成列表达式需要人工转换：\(column.name)。", "Cross-engine generated expressions require manual conversion: \(column.name).") }
        if source == .postgresql && (column.type.lowercased().hasPrefix("bit") || column.type.lowercased().hasPrefix("varbit")) {
            throw TransferFailure("PostgreSQL 位串跨引擎需要显式转换：\(column.name)。", "PostgreSQL bit strings require explicit cross-engine conversion: \(column.name).")
        }
        let type = try convertedType(column.type, target: target)
        let identity = column.extra.lowercased().contains("auto_increment") || column.extra.contains("IDENTITY") || column.defaultValue?.hasPrefix("nextval(") == true
        if identity && target == .postgresql && !["smallint", "integer", "bigint"].contains(type) { throw TransferFailure("自增列超出 PostgreSQL identity 可用整数类型：\(column.name)。", "The auto-increment column exceeds PostgreSQL identity integer types: \(column.name).") }
        var defaultValue = column.defaultValue
        if identity { defaultValue = nil }
        else if let value = defaultValue {
            let normalized = value.uppercased()
            if normalized == "CURRENT_TIMESTAMP" || normalized == "CURRENT_TIMESTAMP()" || normalized == "NOW()" { defaultValue = "CURRENT_TIMESTAMP" }
            else if value.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil || ["NULL", "TRUE", "FALSE"].contains(normalized) { }
            else if source == .mysql { defaultValue = try TransferSQL.string(value, type: target) }
            else if value.hasPrefix("'") && value.hasSuffix("'::text") { defaultValue = String(value.dropLast(6)) }
            else { throw TransferFailure("默认值无法安全跨引擎转换：\(column.name)。", "Cannot safely convert the cross-engine default: \(column.name).") }
        }
        if type == "boolean", defaultValue == "0" || defaultValue == "1" { defaultValue = defaultValue == "1" ? "TRUE" : "FALSE" }
        return .init(name: column.name, type: type, collation: nil, isNullable: column.isNullable, key: column.key, defaultValue: defaultValue, extra: identity ? (target == .postgresql ? "IDENTITY" : "auto_increment") : "", comment: column.comment)
    }

    static func convertedType(_ original: String, target: DatabaseType) throws -> String {
        var type = original.lowercased()
        for (source, canonical) in [("decimalv3", "decimal"), ("decimalv2", "decimal"), ("datetimev2", "datetime"), ("datev2", "date")] {
            if type == source || type.hasPrefix(source + "(") { type = canonical + type.dropFirst(source.count); break }
        }
        let base = type.split(separator: "(").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? type
        if target == .postgresql {
            if type.contains("unsigned") { return type.hasPrefix("bigint") ? "numeric(20,0)" : "bigint" }
            if TransferSQL.isBinary(type) { return "bytea" }
            if ["bool", "boolean"].contains(base) { return "boolean" }
            if ["tinyint", "smallint"].contains(base) { return "smallint" }
            if ["int", "integer", "mediumint"].contains(base) { return "integer" }
            if base == "bigint" { return "bigint" }
            if ["decimal", "numeric"].contains(base) { return type }
            if ["float", "double", "double precision"].contains(base) { return "double precision" }
            if base == "date" { return "date" }
            if ["datetime", "timestamp"].contains(base) { return type.replacingOccurrences(of: "datetime", with: "timestamp") }
            if base == "time" { return type }
            if ["json", "jsonb"].contains(base) { return "jsonb" }
            if ["char", "varchar"].contains(base) { return type }
            if ["text", "tinytext", "mediumtext", "longtext", "string", "enum", "set"].contains(base) { return "text" }
        } else {
            if TransferSQL.isBinary(type) { return "longblob" }
            // PostgreSQL text/unbounded varchar and Doris STRING exceed MySQL
            // TEXT's 64 KiB limit. Preserve their capacity rather than truncating.
            if base == "string" || base == "text" || type == "character varying" { return "longtext" }
            if ["tinyint", "smallint", "int", "integer", "mediumint", "bigint", "float", "double", "char", "varchar", "datetime", "time"].contains(base) { return type }
            if ["boolean", "bool"].contains(base) { return "boolean" }
            if ["smallint", "integer", "bigint", "date", "text"].contains(base) { return type }
            if base == "numeric" || base == "decimal" { return type.replacingOccurrences(of: "numeric", with: "decimal") }
            if base == "real" || base == "double precision" { return "double" }
            if type.hasPrefix("character varying") { return type.replacingOccurrences(of: "character varying", with: "varchar") }
            if type.hasPrefix("character(") { return type.replacingOccurrences(of: "character", with: "char") }
            if type.hasPrefix("timestamp") && !type.contains("with time zone") { return "datetime(6)" }
            if ["json", "jsonb"].contains(base) { return "json" }
        }
        throw TransferFailure("暂不能无损转换类型：\(original)。", "Cannot losslessly convert type: \(original).")
    }

    static func createTable(columns: [WorkspaceDatabaseColumn], name: String, connection: TransferConnection) throws -> String {
        let type = connection.type, d = TransferSQL.dialect(type)
        let fields = try columns.map { column -> String in
            guard !column.type.contains(";"), !column.type.isEmpty else { throw TransferFailure("字段类型无效。", "Invalid column type.") }
            var definition = "\(d.identifier(column.name)) \(column.type)"
            if type == .postgresql, let collation = column.collation { definition += " COLLATE \(collation)" }
            if column.isGenerated { definition += " GENERATED ALWAYS AS (\(column.generationExpression)) STORED" }
            else if column.extra.contains("IDENTITY") || column.extra.lowercased().contains("auto_increment") || column.defaultValue?.hasPrefix("nextval(") == true {
                definition += type == .postgresql ? (column.extra.contains("ALWAYS") ? " GENERATED ALWAYS AS IDENTITY" : " GENERATED BY DEFAULT AS IDENTITY") : " AUTO_INCREMENT"
            } else if let value = column.defaultValue { definition += " DEFAULT \(value)" }
            if !column.isNullable { definition += " NOT NULL" }
            if type == .mysql && !column.comment.isEmpty {
                // Generic MySQL DDL is executed with NO_BACKSLASH_ESCAPES; raw
                // same-engine SHOW CREATE DDL instead uses the captured source mode.
                definition += " COMMENT '" + column.comment.replacingOccurrences(of: "'", with: "''") + "'"
            }
            return definition
        }
        // MySQL requires an AUTO_INCREMENT column to be indexed in the CREATE statement.
        let primary = columns.filter { $0.key == "PRI" }.map { d.identifier($0.name) }
        var definitions = fields
        if type == .mysql && !primary.isEmpty { definitions.append("PRIMARY KEY (\(primary.joined(separator: ", ")))") }
        return "CREATE TABLE \(TransferSQL.qualified(connection.endpoint, name, type: type)) (\n  \(definitions.joined(separator: ",\n  "))\n)" + (type == .mysql ? " ENGINE=InnoDB" : "")
    }

    static func comments(columns: [WorkspaceDatabaseColumn], name: String, connection: TransferConnection) throws -> [String] {
        guard connection.type == .postgresql else { return [] }
        return try columns.filter { !$0.comment.isEmpty }.map { column in
            "COMMENT ON COLUMN \(TransferSQL.qualified(connection.endpoint, name, type: .postgresql)).\(TransferSQL.dialect(.postgresql).identifier(column.name)) IS \(try TransferSQL.string(column.comment, type: .postgresql))"
        }
    }

    static func postgresTypes(_ object: TransferObject, source: TransferConnection, target: TransferConnection,
                              sourceSession: any WorkspaceSession, targetSession: any WorkspaceSession, planned: inout Set<String>) async throws -> [String] {
        guard let oid = UInt64(object.identity) else { return [] }
        let result = try await DataTransferCatalog.query("SELECT DISTINCT t.oid::text AS oid,n.nspname AS namespace,t.typname AS name,t.typtype::text AS kind FROM pg_attribute a JOIN pg_type original ON original.oid=a.atttypid JOIN pg_type t ON t.oid=CASE WHEN original.typelem<>0 AND original.typlen=-1 THEN original.typelem ELSE original.oid END JOIN pg_namespace n ON n.oid=t.typnamespace WHERE a.attrelid=\(oid) AND a.attnum>0 AND NOT a.attisdropped AND n.nspname<>'pg_catalog'", session: sourceSession, database: source.endpoint.database)
        var statements: [String] = []
        for row in result.rows {
            guard let name = result.text(row, "name"), let typeID = result.text(row, "oid"), UInt64(typeID) != nil else { continue }
            guard result.text(row, "kind") == "e", result.text(row, "namespace") == source.endpoint.namespace else {
                throw TransferFailure("自定义类型需要先在目标准备兼容定义：\(name)。当前自动迁移支持所选 Schema 内的枚举及枚举数组。", "Prepare a compatible custom type on the target: \(name). Automatic type migration supports enums and enum arrays in the selected schema.")
            }
            if planned.contains(name) { continue }
            let labels = try await DataTransferCatalog.query("SELECT enumlabel AS label FROM pg_enum WHERE enumtypid=\(typeID) ORDER BY enumsortorder", session: sourceSession, database: source.endpoint.database)
            let values = labels.rows.compactMap { labels.text($0, "label") }
            let existing = try await DataTransferCatalog.query("SELECT t.oid::text AS oid,t.typtype::text AS kind FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname=\(try TransferSQL.string(target.endpoint.namespace, type: .postgresql)) AND t.typname=\(try TransferSQL.string(name, type: .postgresql))", session: targetSession, database: target.endpoint.database)
            if let match = existing.rows.first {
                guard let targetOID = existing.text(match, "oid"), UInt64(targetOID) != nil, existing.text(match, "kind") == "e" else { throw TransferFailure("目标自定义类型不兼容：\(name)。", "Incompatible target custom type: \(name).") }
                let actual = try await DataTransferCatalog.query("SELECT enumlabel AS label FROM pg_enum WHERE enumtypid=\(targetOID) ORDER BY enumsortorder", session: targetSession, database: target.endpoint.database)
                guard actual.rows.compactMap({ actual.text($0, "label") }) == values else { throw TransferFailure("目标枚举值或顺序不同：\(name)。", "Target enum values or ordering differ: \(name).") }
            } else {
                let literals = try values.map { try TransferSQL.string($0, type: .postgresql) }.joined(separator: ", ")
                statements.append("CREATE TYPE \(TransferSQL.qualified(target.endpoint, name, type: .postgresql)) AS ENUM (\(literals))")
            }
            planned.insert(name)
        }
        return statements
    }

    static func splitMySQLForeignKeys(_ sql: String) throws -> (ddl: String, keys: [String]) {
        let tokens = try TransferSQL.tokens(sql)
        guard let open = tokens.firstIndex(where: { $0.value == "(" }) else { throw TransferFailure("建表定义无字段列表。", "CREATE TABLE has no column list.") }
        var depth = 1, start = tokens[open].range.upperBound, pieces: [String] = [], close: String.Index?
        for token in tokens.dropFirst(open + 1) {
            if token.value == "(" { depth += 1 }
            if token.value == ")" { depth -= 1 }
            if depth == 1 && token.value == "," || depth == 0 {
                pieces.append(String(sql[start..<token.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
                start = token.range.upperBound
                if depth == 0 { close = token.range.lowerBound; break }
            }
        }
        guard let close else { throw TransferFailure("建表定义括号不完整。", "Unbalanced CREATE TABLE definition.") }
        var keys: [String] = [], fields: [String] = []
        for piece in pieces {
            let parts = try TransferSQL.tokens(piece).map { $0.value.uppercased() }
            if parts.contains("FOREIGN") && parts.contains("REFERENCES") { keys.append(piece) } else { fields.append(piece) }
        }
        let ddl = String(sql[..<tokens[open].range.upperBound]) + "\n" + fields.joined(separator: ",\n") + "\n" + String(sql[close...])
        return (ddl, keys)
    }

    static func referencedTable(_ sql: String) throws -> String {
        let parts = try TransferSQL.tokens(sql)
        guard let index = parts.firstIndex(where: { $0.value.uppercased() == "REFERENCES" }), index + 1 < parts.count else { return "" }
        return index + 3 < parts.count && parts[index + 2].value == "." ? parts[index + 3].value : parts[index + 1].value
    }

    static func rewriteForeignKey(_ sql: String, target: TransferConnection, source: TransferConnection, tableMapping: [String: String], constraintName: String) throws -> String {
        let parts = try TransferSQL.tokens(sql)
        guard let foreign = parts.firstIndex(where: { $0.value.uppercased() == "FOREIGN" }) else { throw TransferFailure("外键定义无效。", "Invalid foreign-key definition.") }
        var result = "CONSTRAINT \(TransferSQL.dialect(target.type).identifier(constraintName)) " + sql[parts[foreign].range.lowerBound...]
        result = try TransferSQL.rewriteQualified(result, sourceNamespace: source.endpoint.namespace, targetNamespace: target.endpoint.namespace, tableNames: tableMapping, type: target.type)
        let rewritten = try TransferSQL.tokens(result)
        if let ref = rewritten.firstIndex(where: { $0.value.uppercased() == "REFERENCES" }), ref + 1 < rewritten.count,
           !(ref + 2 < rewritten.count && rewritten[ref + 2].value == ".") {
            let name = rewritten[ref + 1].value
            result.replaceSubrange(rewritten[ref + 1].range, with: TransferSQL.qualified(target.endpoint, tableMapping[name] ?? name, type: target.type))
        }
        return result
    }

    static func tableDependencies(_ name: String, connection: TransferConnection, session: any WorkspaceSession) async throws -> [String] {
        let namespace = try TransferSQL.string(connection.endpoint.namespace, type: connection.type), table = try TransferSQL.string(name, type: connection.type)
        let sql = connection.type == .postgresql
            ? "SELECT r.relname AS name FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_class r ON r.oid=k.confrelid WHERE k.contype='f' AND n.nspname=\(namespace) AND c.relname=\(table)"
            : "SELECT REFERENCED_TABLE_NAME AS name FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=\(namespace) AND TABLE_NAME=\(table) AND REFERENCED_TABLE_NAME IS NOT NULL"
        if connection.type == .doris { return [] }
        let result = try await DataTransferCatalog.query(sql, session: session, database: connection.endpoint.database)
        return result.rows.compactMap { result.text($0, "name") }
    }

    static func postgresConstraints(_ object: TransferObject, source: TransferConnection, target: TransferConnection,
                                    session: any WorkspaceSession, mapping: [String: String], id: UUID, itemIndex: Int) async throws -> (statements: [String], keys: [TransferForeignKey], dependencies: [String]) {
        guard let oid = UInt64(object.identity) else { throw TransferFailure("表标识无效。", "Invalid table identity.") }
        let constraints = try await DataTransferCatalog.query("SELECT k.conname AS name,k.contype::text AS kind,pg_get_constraintdef(k.oid,true) AS ddl, r.relname AS referenced FROM pg_constraint k LEFT JOIN pg_class r ON r.oid=k.confrelid WHERE k.conrelid=\(oid) AND k.contype IN ('p','u','c','f','x') ORDER BY k.conname", session: session, database: source.endpoint.database)
        var statements: [String] = [], keys: [TransferForeignKey] = [], dependencies: [String] = []
        let name = mapping[object.name] ?? object.name, qualified = TransferSQL.qualified(target.endpoint, name, type: .postgresql)
        for (index, row) in constraints.rows.enumerated() {
            guard let ddl = constraints.text(row, "ddl") else { continue }
            let constraint = "qc_\(id.uuidString.prefix(8))_\(itemIndex)_\(index)"
            if constraints.text(row, "kind") == "f" {
                let rewritten = try rewriteForeignKey(ddl, target: target, source: source, tableMapping: mapping, constraintName: constraint)
                let referenced = constraints.text(row, "referenced") ?? ""
                dependencies.append(referenced); keys.append(.init(table: name, referencedTable: mapping[referenced] ?? referenced, sql: "ALTER TABLE \(qualified) ADD \(rewritten)"))
            } else {
                let rewritten = try TransferSQL.rewriteQualified(ddl, sourceNamespace: source.endpoint.namespace, targetNamespace: target.endpoint.namespace, tableNames: mapping, type: .postgresql)
                statements.append("ALTER TABLE \(qualified) ADD CONSTRAINT \(TransferSQL.dialect(.postgresql).identifier(constraint)) \(rewritten)")
            }
        }
        let indexes = try await DataTransferCatalog.query("SELECT i.indexrelid::text AS identity,pg_get_indexdef(i.indexrelid) AS ddl FROM pg_index i WHERE i.indrelid=\(oid) AND NOT EXISTS(SELECT 1 FROM pg_constraint k WHERE k.conindid=i.indexrelid)", session: session, database: source.endpoint.database)
        for (index, row) in indexes.rows.enumerated() {
            guard let ddl = indexes.text(row, "ddl") else { continue }
            var rewritten = try TransferSQL.rewriteQualified(ddl, sourceNamespace: source.endpoint.namespace, targetNamespace: target.endpoint.namespace, tableNames: mapping, type: .postgresql)
            rewritten = try TransferSQL.retargetCreate(rewritten, keyword: "INDEX", target: TransferSQL.dialect(.postgresql).identifier("qc_\(id.uuidString.prefix(8))_\(itemIndex)_idx\(index)"))
            statements.append(rewritten)
        }
        return (statements, keys, dependencies)
    }

    static func order(_ items: [TransferPlanItem]) throws -> [TransferPlanItem] {
        var pending = items.sorted { $0.object.kind.order < $1.object.kind.order }, result: [TransferPlanItem] = []
        let names = Set(items.map { $0.object.name })
        var done: Set<String> = []
        while !pending.isEmpty {
            if let index = pending.firstIndex(where: { item in item.dependencies.filter { $0 != item.object.name && names.contains($0) }.allSatisfy(done.contains) }) {
                let item = pending.remove(at: index); result.append(item)
                done.insert(item.object.name)
            } else {
                // New tables get their FKs after all rows. Existing cycles cannot be safely inserted.
                let tables = pending.filter { $0.object.kind == .table }
                guard !tables.isEmpty, tables.allSatisfy({ !$0.statements.isEmpty }) else { throw TransferFailure("对象存在依赖循环，请先人工处理依赖。", "Objects contain a dependency cycle. Resolve dependencies first.") }
                for table in tables { result.append(table); done.insert(table.object.name) }
                pending.removeAll { $0.object.kind == .table }
            }
        }
        return result
    }

    static func addOwnership(to plan: inout DataTransferPlan, sourceSession: any WorkspaceSession, targetSession: any WorkspaceSession) async throws {
        guard plan.ownership != .skip else { return }
        let roles = try await DataTransferCatalog.query("SELECT rolname AS name FROM pg_roles", session: targetSession, database: plan.target.endpoint.database)
        let names = Set(roles.rows.compactMap { roles.text($0, "name") })
        let current = try await DataTransferCatalog.query("SELECT current_user AS name", session: targetSession, database: plan.target.endpoint.database)
        let currentName = current.rows.first.flatMap { current.text($0, "name") } ?? ""
        for item in plan.items where !item.statements.isEmpty && item.object.kind != .trigger {
            guard let oid = UInt64(item.object.identity) else { continue }
            let routine = item.object.kind == .function || item.object.kind == .procedure
            let sql = routine ? "SELECT pg_get_userbyid(proowner) AS owner,pg_get_function_identity_arguments(oid) AS args FROM pg_proc WHERE oid=\(oid)" : "SELECT pg_get_userbyid(relowner) AS owner FROM pg_class WHERE oid=\(oid)"
            let result = try await DataTransferCatalog.query(sql, session: sourceSession, database: plan.source.endpoint.database)
            guard let row = result.rows.first, let owner = result.text(row, "owner") else { continue }
            if !names.contains(owner) { plan.missingOwners.append(owner) }
            let effective = !names.contains(owner) && plan.ownership == .reassignMissing ? currentName : owner
            let keyword: String
            switch item.object.kind {
            case .table: keyword = "TABLE"
            case .view: keyword = "VIEW"
            case .materializedView: keyword = "MATERIALIZED VIEW"
            case .sequence: keyword = "SEQUENCE"
            case .function: keyword = "FUNCTION"
            case .procedure: keyword = "PROCEDURE"
            default: continue
            }
            var qualified = TransferSQL.qualified(plan.target.endpoint, item.targetName, type: .postgresql)
            if routine {
                let args = try TransferSQL.rewriteQualified(result.text(row, "args") ?? "", sourceNamespace: plan.source.endpoint.namespace, targetNamespace: plan.target.endpoint.namespace, tableNames: [:], type: .postgresql)
                qualified += "(\(args))"
            }
            plan.ownershipStatements.append("ALTER \(keyword) \(qualified) OWNER TO \(TransferSQL.dialect(.postgresql).identifier(effective))")
        }
        plan.missingOwners = Array(Set(plan.missingOwners)).sorted()
    }
}
