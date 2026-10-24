import Foundation
#if os(iOS)
import QueryCraftMobileCore
#endif

enum WorkspaceTableAction: String, CaseIterable, Identifiable, Sendable {
    case rename, drop, truncate, clear, resetAutoIncrement, setAutoIncrement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rename: AppCopy.current.text("重命名表", "Rename Table")
        case .drop: AppCopy.current.text("删除表", "Drop Table")
        case .truncate: AppCopy.current.text("截断表", "Truncate Table")
        case .clear: AppCopy.current.text("清空表", "Clear Table")
        case .resetAutoIncrement: AppCopy.current.text("重置自增", "Reset Auto Increment")
        case .setAutoIncrement: AppCopy.current.text("设置自增值", "Set Auto Increment")
        }
    }

    var isDestructive: Bool { self != .rename }

    func unavailabilityReason(for databaseType: DatabaseType) -> String? {
        switch databaseType {
        case .mysql, .postgresql: return nil
        case .doris:
            switch self {
            case .rename, .drop, .truncate: return nil
            case .clear:
                return AppCopy.current.text("Doris 的 DELETE 受表模型和分区限制，请使用截断表。", "Doris DELETE depends on the table model and partitions. Use Truncate Table.")
            case .resetAutoIncrement, .setAutoIncrement:
                return AppCopy.current.text("Doris 不支持修改已有表的自增计数。", "Doris cannot alter an existing table's auto-increment counter.")
            }
        case .redis, .elasticsearch, .kafka:
            return AppCopy.current.text("此驱动没有 SQL 表操作。", "This driver has no SQL table operations.")
        }
    }

    func explanation(for databaseType: DatabaseType) -> String {
        switch self {
        case .rename:
            return AppCopy.current.text("更改表名，保留表结构和数据。", "Change the table name, keeping its structure and data.")
        case .drop:
            return AppCopy.current.text("删除表结构及全部数据。应用无法撤销此操作。", "Delete the table and all its data. The app cannot undo this operation.")
        case .truncate:
            let identity = databaseType == .mysql
                ? AppCopy.current.text("MySQL 同时重置自增计数。", "MySQL also resets the auto-increment counter.")
                : databaseType == .postgresql
                    ? AppCopy.current.text("PostgreSQL 保留当前序列计数。", "PostgreSQL keeps the current sequence counters.") : ""
            return AppCopy.current.text("使用 TRUNCATE 快速移除全部数据，保留表结构。应用无法撤销此操作。", "Use TRUNCATE to remove all data while keeping the table structure. The app cannot undo this operation.") + " " + identity
        case .clear:
            return AppCopy.current.text("使用 DELETE FROM 删除全部行，保留表结构和自增计数；可能触发删除触发器或外键级联。大表可能耗时较长，应用无法撤销此操作。", "Use DELETE FROM to remove all rows, keeping the structure and counters. Delete triggers or foreign-key cascades may run. Large tables can take time; the app cannot undo this operation.")
        case .resetAutoIncrement, .setAutoIncrement:
            let prefix = self == .resetAutoIncrement
                ? AppCopy.current.text("将下一自增起始值设为 1。", "Set the next auto-increment starting value to 1.")
                : AppCopy.current.text("设置下一自增起始值。", "Set the next auto-increment starting value.")
            return prefix + " " + (databaseType == .mysql
                ? AppCopy.current.text("不删除数据。MySQL 可能将过低的值调整到现有最大值之后；表必须有自增列。", "No data is deleted. MySQL may adjust a low value above the current maximum; the table must have an auto-increment column.")
                : AppCopy.current.text("不删除数据。将修改此表所有 serial / identity 列所属的序列；过低的值可能导致后续插入主键冲突。没有所属序列时会报错。", "No data is deleted. All sequences owned by this table's serial / identity columns will change. Low values may cause duplicate keys on later inserts. Tables without owned sequences report an error."))
        }
    }
}

struct WorkspaceTableActionRequest: Identifiable {
    let id = UUID()
    let action: WorkspaceTableAction
    let selection: WorkspaceDatabaseObjectSelection
    let workspaceID: UUID
    let connectionID: UUID

    init(action: WorkspaceTableAction, selection: WorkspaceDatabaseObjectSelection,
         workspaceID: UUID, connectionID: UUID = UUID()) {
        self.action = action
        self.selection = selection
        self.workspaceID = workspaceID
        self.connectionID = connectionID
    }
}

struct WorkspaceTableActionStatement: Equatable, Sendable {
    let sql: String
    let kind: SQLStatementKind
    let resultingSelection: WorkspaceDatabaseObjectSelection?

    static func make(action: WorkspaceTableAction, selection: WorkspaceDatabaseObjectSelection,
                     databaseType: DatabaseType, input: String) throws -> Self {
        guard selection.kind == .table,
              action.unavailabilityReason(for: databaseType) == nil,
              let dialect = WorkspaceSQLExportDialect(databaseType: databaseType) else {
            throw WorkspaceTableActionError.unsupported
        }
        let schema = selection.object.schemaName ?? "public"
        let table = databaseType == .postgresql
            ? dialect.identifier(schema) + "." + dialect.identifier(selection.object.nameWithinSchema)
            : dialect.identifier(selection.databaseName) + "." + dialect.identifier(selection.objectName)
        switch action {
        case .rename:
            let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("\0"),
                  name != (databaseType == .postgresql ? selection.object.nameWithinSchema : selection.objectName) else {
                throw WorkspaceTableActionError.invalidName
            }
            let sql = databaseType == .mysql
                ? "RENAME TABLE \(table) TO \(dialect.identifier(selection.databaseName)).\(dialect.identifier(name))"
                : "ALTER TABLE \(table) RENAME \(databaseType == .postgresql ? "TO " : "")\(dialect.identifier(name))"
            return Self(sql: sql, kind: .ddl(.alter), resultingSelection: .init(
                databaseName: selection.databaseName,
                objectName: databaseType == .postgresql ? WorkspaceDatabaseObject.postgreSQLName(schema: schema, table: name) : name, kind: .table))
        case .drop:
            return Self(sql: "DROP TABLE \(table)", kind: .ddl(.drop), resultingSelection: nil)
        case .truncate:
            return Self(sql: "TRUNCATE TABLE \(table)" + (databaseType == .postgresql ? " CONTINUE IDENTITY RESTRICT" : ""),
                        kind: .ddl(.truncate), resultingSelection: selection)
        case .clear:
            return Self(sql: "DELETE FROM \(table)", kind: .delete(hasWhereClause: false), resultingSelection: selection)
        case .resetAutoIncrement, .setAutoIncrement:
            let value = action == .resetAutoIncrement ? "1" : input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = UInt64(value), number > 0,
                  databaseType != .postgresql || number <= UInt64(Int64.max) else {
                throw WorkspaceTableActionError.invalidAutoIncrement
            }
            let sql: String
            if databaseType == .mysql {
                sql = "ALTER TABLE \(table) AUTO_INCREMENT = \(number)"
            } else {
                // Resolve only owned sequences, including identity columns; never infer sequence names.
                // A single DO statement makes all restarts atomic and locks the table during resolution.
                let target = try dialect.literal(.text(table))
                let body = """
                DECLARE sequence_name text; found_sequence boolean := false;
                BEGIN
                    EXECUTE 'LOCK TABLE ' || \(target) || ' IN ACCESS EXCLUSIVE MODE';
                    FOR sequence_name IN
                        SELECT DISTINCT pg_get_serial_sequence(\(target), attname)
                        FROM pg_attribute
                        WHERE attrelid = \(target)::regclass AND attnum > 0 AND NOT attisdropped
                    LOOP
                        IF sequence_name IS NOT NULL THEN
                            EXECUTE format('ALTER SEQUENCE %s RESTART WITH \(number)', sequence_name);
                            found_sequence := true;
                        END IF;
                    END LOOP;
                    IF NOT found_sequence THEN
                        RAISE EXCEPTION 'Table has no owned serial or identity sequence';
                    END IF;
                END;
                """
                sql = "DO " + (try dialect.literal(.text(body)))
            }
            return Self(sql: sql, kind: .ddl(.alter), resultingSelection: selection)
        }
    }
}

enum WorkspaceTableActionError: LocalizedError {
    case unsupported, invalidName, invalidAutoIncrement, pendingChanges, noAutoIncrement

    var errorDescription: String? {
        switch self {
        case .unsupported: AppCopy.current.text("此驱动不支持该表操作。", "This driver does not support this table operation.")
        case .invalidName: AppCopy.current.text("请输入与原表名不同的有效表名。", "Enter a valid table name different from the current name.")
        case .invalidAutoIncrement: AppCopy.current.text("请输入范围内的正整数自增值。", "Enter a positive auto-increment integer within the supported range.")
        case .pendingChanges: AppCopy.current.text("请先保存或放弃此表的待处理更改。", "Save or discard this table's pending changes first.")
        case .noAutoIncrement: AppCopy.current.text("此表没有自增列。", "This table has no auto-increment column.")
        }
    }
}
