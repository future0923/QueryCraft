import Foundation

struct TransferConnection: Sendable {
    let endpoint: TransferEndpoint
    let configuration: DatabaseConnectionConfiguration
    var type: DatabaseType { configuration.databaseType }
}

struct TransferQueryResult: Sendable {
    let columns: [WorkspaceDatabaseDataColumn]
    let rows: [WorkspaceDatabaseDataRow]
    func text(_ row: WorkspaceDatabaseDataRow, _ name: String) -> String? {
        guard let index = columns.firstIndex(where: { $0.name == name }), case let .text(value) = row.value(at: index) else { return nil }
        return value
    }
}

private actor TransferRowCollector {
    var columns: [WorkspaceDatabaseDataColumn] = []
    var rows: [WorkspaceDatabaseDataRow] = []
    func append(_ batch: WorkspaceDatabaseDataBatch) throws {
        if !columns.isEmpty && columns != batch.columns { throw TransferFailure("读取期间字段发生变化。", "Result columns changed during reading.") }
        columns = batch.columns; rows.append(contentsOf: batch.rows)
    }
    func result() -> TransferQueryResult { .init(columns: columns, rows: rows) }
}

struct DataTransferCatalog: Sendable {
    let factory: any WorkspaceSessionFactory
    init(factory: any WorkspaceSessionFactory = DefaultWorkspaceSessionFactory()) { self.factory = factory }

    func open(_ connection: TransferConnection) async throws -> any WorkspaceSession {
        let session = await factory.makeSession(configuration: connection.configuration.selecting(database: connection.endpoint.database.isEmpty ? nil : connection.endpoint.database))
        do {
            try await session.connect()
            if connection.type == .postgresql {
                // Force PostgreSQL deparsers to qualify user objects, including public.
                do { _ = try await session.executeStatement("SET search_path = pg_catalog", kind: .control, database: connection.endpoint.database) { _ in } }
                catch WorkspaceSessionError.transactionStateUnavailable { }
            }
            try Task.checkCancellation(); return session
        }
        catch { await session.close(); throw error }
    }

    static func query(_ sql: String, session: any WorkspaceSession, database: String) async throws -> TransferQueryResult {
        try Task.checkCancellation()
        let collector = TransferRowCollector()
        let result = try await session.executeStatement(sql, kind: .read, database: database) { try await collector.append($0) }
        let collected = await collector.result()
        return .init(columns: collected.columns.isEmpty ? result.columns : collected.columns, rows: collected.rows)
    }

    static func serverIdentity(_ connection: TransferConnection, session: any WorkspaceSession) async throws -> String {
        let primary = connection.type == .postgresql
            ? "SELECT system_identifier::text AS identity FROM pg_control_system()"
            : "SELECT @@server_uuid AS identity"
        if let result = try? await query(primary, session: session, database: connection.endpoint.database),
           let row = result.rows.first, let identity = result.text(row, "identity"), !identity.isEmpty { return identity }
        let fallback = connection.type == .postgresql
            ? "SELECT inet_server_addr()::text || ':' || inet_server_port()::text || ':' || pg_postmaster_start_time()::text AS identity"
            : "SELECT CONCAT(@@hostname,':',@@port,':',@@server_id) AS identity"
        let result = try await query(fallback, session: session, database: connection.endpoint.database)
        guard let row = result.rows.first, let identity = result.text(row, "identity"), !identity.isEmpty else {
            throw TransferFailure("无法确认数据库实例身份，已停止传输。", "Cannot verify the database instance identity. Transfer stopped.")
        }
        return identity
    }

    func databases(_ configuration: DatabaseConnectionConfiguration) async throws -> [String] {
        let connection = TransferConnection(endpoint: TransferEndpoint(), configuration: configuration)
        let session = try await open(connection)
        do { let result = try await session.fetchDatabases(); await session.close(); return result }
        catch { await session.close(); throw error }
    }

    func schemas(_ connection: TransferConnection) async throws -> [String] {
        let session = try await open(connection)
        do { let result = try await session.fetchSchemas(in: connection.endpoint.database); await session.close(); return result }
        catch { await session.close(); throw error }
    }

    func objects(_ connection: TransferConnection) async throws -> [TransferObject] {
        let session = try await open(connection)
        do { let result = try await Self.objects(connection, session: session); await session.close(); return result }
        catch { await session.close(); throw error }
    }

    static func objects(_ connection: TransferConnection, session: any WorkspaceSession) async throws -> [TransferObject] {
        let endpoint = connection.endpoint, type = connection.type
        let namespace = try TransferSQL.string(endpoint.namespace, type: type)
        var result: [TransferObject] = []
        if type == .postgresql {
            let relations = try await query("SELECT c.relname AS name, c.relkind::text AS kind, c.oid::text AS identity FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=\(namespace) AND c.relkind IN ('r','p','v','m','S') ORDER BY c.relname", session: session, database: endpoint.database)
            for row in relations.rows {
                guard let name = relations.text(row, "name"), let kind = relations.text(row, "kind") else { continue }
                let objectKind: TransferObjectKind = kind == "S" ? .sequence : kind == "m" ? .materializedView : kind == "v" ? .view : .table
                result.append(.init(kind: objectKind, name: name, identity: relations.text(row, "identity") ?? ""))
            }
            let routines = try await query("SELECT p.proname AS name, p.prokind::text AS kind, p.oid::text AS identity, pg_get_function_identity_arguments(p.oid) AS args,oidvectortypes(p.proargtypes) AS argument_types FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=\(namespace) AND p.prokind IN ('f','p') ORDER BY p.proname,p.oid", session: session, database: endpoint.database)
            for row in routines.rows {
                guard let name = routines.text(row, "name") else { continue }
                result.append(.init(kind: routines.text(row, "kind") == "p" ? .procedure : .function, name: name, identity: routines.text(row, "identity") ?? "", signature: routines.text(row, "args") ?? "", argumentTypes: routines.text(row, "argument_types") ?? ""))
            }
            let triggers = try await query("SELECT t.tgname AS name, t.oid::text AS identity, c.relname AS parent FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=\(namespace) AND NOT t.tgisinternal ORDER BY c.relname,t.tgname", session: session, database: endpoint.database)
            for row in triggers.rows {
                if let name = triggers.text(row, "name") { result.append(.init(kind: .trigger, name: name, identity: triggers.text(row, "identity") ?? "", parentTable: triggers.text(row, "parent"))) }
            }
        } else {
            let tables = try await query("SELECT TABLE_NAME AS name, TABLE_TYPE AS kind FROM information_schema.TABLES WHERE TABLE_SCHEMA=\(namespace) ORDER BY TABLE_NAME", session: session, database: endpoint.database)
            for row in tables.rows {
                if let name = tables.text(row, "name") { result.append(.init(kind: tables.text(row, "kind") == "VIEW" ? .view : .table, name: name)) }
            }
            if type == .mysql {
                let routines = try await query("SELECT ROUTINE_NAME AS name, ROUTINE_TYPE AS kind FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=\(namespace) ORDER BY ROUTINE_NAME", session: session, database: endpoint.database)
                for row in routines.rows {
                    if let name = routines.text(row, "name") { result.append(.init(kind: routines.text(row, "kind") == "PROCEDURE" ? .procedure : .function, name: name)) }
                }
                let triggers = try await query("SELECT TRIGGER_NAME AS name, EVENT_OBJECT_TABLE AS parent FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=\(namespace) ORDER BY TRIGGER_NAME", session: session, database: endpoint.database)
                for row in triggers.rows { if let name = triggers.text(row, "name") { result.append(.init(kind: .trigger, name: name, parentTable: triggers.text(row, "parent"))) } }
                let events = try await query("SELECT EVENT_NAME AS name FROM information_schema.EVENTS WHERE EVENT_SCHEMA=\(namespace) ORDER BY EVENT_NAME", session: session, database: endpoint.database)
                for row in events.rows { if let name = events.text(row, "name") { result.append(.init(kind: .event, name: name)) } }
            }
        }
        return result.sorted { $0.kind.order == $1.kind.order ? $0.name < $1.name : $0.kind.order < $1.kind.order }
    }

    static func columns(_ object: TransferObject, connection: TransferConnection, session: any WorkspaceSession) async throws -> [WorkspaceDatabaseColumn] {
        let type = connection.type, namespace = try TransferSQL.string(connection.endpoint.namespace, type: type), name = try TransferSQL.string(object.name, type: type)
        let sql: String
        if type == .postgresql {
            sql = """
            SELECT a.attname AS name, pg_catalog.format_type(a.atttypid,a.atttypmod) AS type,
            CASE WHEN a.attnotnull THEN 'NO' ELSE 'YES' END AS nullable,
            CASE WHEN EXISTS(SELECT 1 FROM pg_index i WHERE i.indrelid=c.oid AND i.indisprimary AND a.attnum=ANY(i.indkey)) THEN 'PRI' ELSE '' END AS key,
            CASE WHEN a.attgenerated<>'' THEN NULL ELSE pg_get_expr(d.adbin,d.adrelid) END AS default_value,
            CASE WHEN a.attgenerated<>'' THEN 'STORED GENERATED' WHEN a.attidentity='a' THEN 'IDENTITY ALWAYS' WHEN a.attidentity='d' THEN 'IDENTITY BY DEFAULT' ELSE '' END AS extra,
            COALESCE(col_description(c.oid,a.attnum),'') AS comment,
            CASE WHEN a.attcollation<>0 THEN quote_ident(cn.nspname)||'.'||quote_ident(co.collname) ELSE NULL END AS collation,
            CASE WHEN a.attgenerated<>'' THEN pg_get_expr(d.adbin,d.adrelid) ELSE '' END AS generation
            FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
            LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum
            LEFT JOIN pg_collation co ON co.oid=a.attcollation LEFT JOIN pg_namespace cn ON cn.oid=co.collnamespace
            WHERE n.nspname=\(namespace) AND c.relname=\(name) AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum
            """
        } else {
            let generation = type == .doris ? "''" : "GENERATION_EXPRESSION"
            sql = "SELECT COLUMN_NAME AS name,COLUMN_TYPE AS type,IS_NULLABLE AS nullable,COLUMN_KEY AS `key`,COLUMN_DEFAULT AS default_value,EXTRA AS extra,COLUMN_COMMENT AS comment,\(generation) AS generation FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=\(namespace) AND TABLE_NAME=\(name) ORDER BY ORDINAL_POSITION"
        }
        let result = try await query(sql, session: session, database: connection.endpoint.database)
        return result.rows.compactMap { row in
            guard let name = result.text(row, "name"), let type = result.text(row, "type") else { return nil }
            return WorkspaceDatabaseColumn(name: name, type: type, collation: result.text(row, "collation"), isNullable: result.text(row, "nullable") == "YES", key: result.text(row, "key") ?? "", defaultValue: result.text(row, "default_value"), extra: result.text(row, "extra") ?? "", comment: result.text(row, "comment") ?? "", generationExpression: result.text(row, "generation") ?? "")
        }
    }

    static func showCreate(_ object: TransferObject, connection: TransferConnection, session: any WorkspaceSession) async throws -> String {
        let type = connection.type, database = connection.endpoint.database
        if type == .postgresql {
            guard let oid = UInt64(object.identity) else { throw TransferFailure("对象标识已失效，请刷新。", "Object identity is stale. Refresh the source.") }
            let sql: String
            switch object.kind {
            case .view, .materializedView: sql = "SELECT pg_get_viewdef(\(oid)::oid,true) AS ddl"
            case .function, .procedure: sql = "SELECT pg_get_functiondef(\(oid)::oid) AS ddl"
            case .trigger: sql = "SELECT pg_get_triggerdef(\(oid)::oid,true) AS ddl"
            case .sequence:
                sql = "SELECT 'CREATE SEQUENCE ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || ' AS ' || format_type(s.seqtypid,NULL) || ' INCREMENT BY ' || s.seqincrement || ' MINVALUE ' || s.seqmin || ' MAXVALUE ' || s.seqmax || ' START WITH ' || s.seqstart || ' CACHE ' || s.seqcache || CASE WHEN s.seqcycle THEN ' CYCLE' ELSE ' NO CYCLE' END AS ddl FROM pg_sequence s JOIN pg_class c ON c.oid=s.seqrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid=\(oid)"
            default: throw TransferFailure("此对象没有可用的独立定义。", "No standalone definition is available for this object.")
            }
            let result = try await query(sql, session: session, database: database)
            guard let row = result.rows.first, let ddl = result.text(row, "ddl"), !ddl.isEmpty else { throw TransferFailure("无法读取对象定义。", "Cannot read the object definition.") }
            return ddl
        }
        let keyword = object.kind == .table ? "TABLE" : object.kind == .view ? "VIEW" : object.kind.rawValue.uppercased()
        let result = try await query("SHOW CREATE \(keyword) \(TransferSQL.qualified(connection.endpoint, object.name, type: type))", session: session, database: database)
        guard let row = result.rows.first, let index = result.columns.firstIndex(where: { $0.name.lowercased().hasPrefix("create ") || $0.name.lowercased() == "sql original statement" }), case let .text(ddl) = row.value(at: index), !ddl.isEmpty else {
            throw TransferFailure("无法读取完整对象定义，可能缺少权限。", "Cannot read the full object definition; check privileges.")
        }
        return ddl
    }

    static func requireTransactionalTable(_ name: String, connection: TransferConnection, session: any WorkspaceSession) async throws {
        guard connection.type == .mysql else { return }
        let namespace = try TransferSQL.string(connection.endpoint.namespace, type: .mysql), table = try TransferSQL.string(name, type: .mysql)
        let result = try await query("SELECT ENGINE AS engine FROM information_schema.TABLES WHERE TABLE_SCHEMA=\(namespace) AND TABLE_NAME=\(table)", session: session, database: connection.endpoint.database)
        guard let row = result.rows.first, result.text(row, "engine")?.caseInsensitiveCompare("InnoDB") == .orderedSame else {
            throw TransferFailure("MySQL 目标表必须使用 InnoDB：\(name)。", "MySQL target tables must use InnoDB: \(name).")
        }
    }
}
