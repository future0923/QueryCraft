import Foundation

/// A review plan is separate from the automatically safe additive subset.
/// It never runs SQL. Destructive statements require explicit review in the UI.
enum SchemaComparisonSQLPlanner {
    static func plan(_ differences: [SchemaComparisonDifference], source: SchemaComparisonSnapshot,
                     target: SchemaComparisonSnapshot, compatible: Bool) -> [SchemaComparisonDifference] {
        guard compatible else { return differences }
        func object(_ snapshot: SchemaComparisonSnapshot, _ name: String) -> SchemaComparisonSnapshot.Object? {
            snapshot.objects.first { snapshot.matchingKey($0.name) == snapshot.matchingKey(name) }
        }
        var result = differences.map { difference in
            var difference = difference
            let s = object(source, difference.table), t = object(target, difference.table)
            let name = t?.name ?? s?.name ?? difference.table
            let qualified = MySQLSchemaDefinition.identifier(target.database) + "." + MySQLSchemaDefinition.identifier(name)
            let sp = s?.definition?.parts.first { $0.key == difference.object }
            let tp = t?.definition?.parts.first { $0.key == difference.object }
            let sameOptions = if let sd = s?.definition, let td = t?.definition {
                MySQLSchemaCompatibility.tableOptions(SchemaComparisonOptions().comparableTokens(sd.options), version: source.version)
                    == MySQLSchemaCompatibility.tableOptions(SchemaComparisonOptions().comparableTokens(td.options), version: target.version)
            } else { false }
            if difference.object == "table", difference.status == .added, let definition = s?.definition,
               definition.parts.allSatisfy({ part in
                   transferableColumn(part, source: source.version, target: target.version, allowsAutoIncrement: true)
                       || MySQLSchemaDefinition.simpleIndexColumns(part) != nil
                       || primaryKey(part) || simpleUniqueKey(part)
               }), transferableOptions(definition.options) {
                difference.reviewSQL = "CREATE TABLE \(qualified) (\n  " + definition.parts.map(\.definition).joined(separator: ",\n  ")
                    + "\n) " + MySQLSchemaCompatibility.tableOptions(definition.options.map(MySQLSchemaDefinition.canonicalToken), version: source.version).joined(separator: " ") + ";"
                difference.planOrder = 0
            } else if difference.object == "table", difference.status == .targetOnly,
                      let definition = t?.definition, !hasForeignKey(definition) {
                // Without complete inbound-reference metadata a DROP can still
                // be rejected by MySQL; retain constraints and never disable FK checks.
                difference.reviewSQL = "DROP TABLE \(qualified);"
                difference.planOrder = 100
            } else if difference.object.hasPrefix("column:"), sameOptions {
                if let sp, [.added, .modified].contains(difference.status),
                   transferableColumn(sp, source: source.version, target: target.version) {
                    let operation = difference.status == .added ? "ADD COLUMN" : "MODIFY COLUMN"
                    difference.reviewSQL = "ALTER TABLE \(qualified) \(operation) \(sp.definition);"
                } else if difference.status == .targetOnly, let tp, let targetDefinition = t?.definition,
                          !hasForeignKey(targetDefinition),
                          !targetDefinition.parts.contains(where: { primaryKey($0) && $0.canonical.contains(MySQLSchemaDefinition.identifier(tp.name)) }) {
                    difference.reviewSQL = "ALTER TABLE \(qualified) DROP COLUMN \(MySQLSchemaDefinition.identifier(tp.name));"
                    difference.planOrder = 30
                }
            } else if difference.object.hasPrefix("index:"), sameOptions {
                if let sp, MySQLSchemaDefinition.simpleIndexColumns(sp) != nil {
                    if difference.status == .added, let targetDefinition = t?.definition,
                       !targetDefinition.parts.contains(where: { $0.indexName?.lowercased() == sp.name.lowercased() }) {
                        difference.reviewSQL = "ALTER TABLE \(qualified) ADD \(sp.definition);"
                        difference.planOrder = 40
                    } else if difference.status == .modified, let tp, MySQLSchemaDefinition.simpleIndexColumns(tp) != nil {
                        difference.reviewSQL = "ALTER TABLE \(qualified) DROP INDEX \(MySQLSchemaDefinition.identifier(tp.name)), ADD \(sp.definition);"
                        difference.planOrder = 40
                    }
                } else if difference.status == .targetOnly, let tp, MySQLSchemaDefinition.simpleIndexColumns(tp) != nil {
                    difference.reviewSQL = "ALTER TABLE \(qualified) DROP INDEX \(MySQLSchemaDefinition.identifier(tp.name));"
                    difference.planOrder = 10
                }
            }
            if difference.reviewSQL != nil && difference.sql == nil {
                difference.explanation = difference.needsDestructiveReview
                    ? AppCopy.current.text("此变更可能删除或转换现有数据。进入下一步审核 SQL 后才可复制或导出。", "This change can remove or convert existing data. Review the SQL in the next step before copying or exporting.")
                    : AppCopy.current.text("已生成目标端变更计划。进入下一步审核 SQL；当前不会直接执行。", "A target-side change is planned. Review the SQL in the next step; it is not executed automatically.")
            }
            return difference
        }
        // New indexes must include the required column additions/modifications.
        for i in result.indices where result[i].object.hasPrefix("index:") && result[i].sqlForReview != nil && result[i].status != .targetOnly {
            guard let definition = object(source, result[i].table)?.definition,
                  let index = definition.parts.first(where: { $0.key == result[i].object }),
                  let columns = MySQLSchemaDefinition.simpleIndexColumns(index) else { continue }
            for column in columns {
                if let dependency = result.first(where: { $0.table == result[i].table && $0.object == "column:" + column.lowercased() && $0.status != .equal }) {
                    if dependency.sqlForReview == nil { result[i].reviewSQL = nil }
                    else { result[i].requiredIDs.insert(dependency.id) }
                }
            }
        }
        for i in result.indices where result[i].object.hasPrefix("column:") && result[i].status == .targetOnly && result[i].reviewSQL != nil {
            guard let definition = object(target, result[i].table)?.definition else { continue }
            let columnName = String(result[i].object.dropFirst(7))
            for index in definition.parts where index.kind == .index {
                guard MySQLSchemaDefinition.simpleIndexColumns(index)?.contains(where: { $0.lowercased() == columnName }) == true else { continue }
                if let dependency = result.first(where: { $0.table == result[i].table && $0.object == index.key && $0.status == .targetOnly && $0.sqlForReview != nil }) {
                    result[i].requiredIDs.insert(dependency.id)
                } else { result[i].reviewSQL = nil }
            }
        }
        return result
    }

    private static func transferableColumn(_ part: MySQLSchemaDefinition.Part, source: String, target: String, allowsAutoIncrement: Bool = false) -> Bool {
        guard part.kind == .column, part.tokens.count > 1,
              ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT", "DECIMAL", "NUMERIC", "DATE", "DATETIME", "TIMESTAMP", "TIME", "YEAR", "CHAR", "VARCHAR", "BINARY", "VARBINARY", "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT", "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB", "JSON", "ENUM", "SET"].contains(part.canonical[1]),
              !part.canonical.contains(where: { ["GENERATED", "AS", "REFERENCES", "INVISIBLE", "PRIMARY", "UNIQUE"].contains($0) }),
              allowsAutoIncrement || !part.canonical.contains("AUTO_INCREMENT") else { return false }
        return MySQLSchemaCompatibility.canTransferColumn(part, from: source, to: target)
    }
    private static func primaryKey(_ part: MySQLSchemaDefinition.Part) -> Bool { part.canonical.first == "PRIMARY" }
    private static func simpleUniqueKey(_ part: MySQLSchemaDefinition.Part) -> Bool {
        guard part.canonical.first == "UNIQUE", part.canonical.count > 3, part.canonical[1] == "KEY" else { return false }
        return MySQLSchemaDefinition.simpleIndexColumns(.init(kind: .index, name: part.name, tokens: ["KEY"] + part.tokens.dropFirst(2))) != nil
    }
    private static func hasForeignKey(_ definition: MySQLSchemaDefinition) -> Bool {
        definition.parts.contains { $0.canonical.contains("REFERENCES") }
    }
    private static func transferableOptions(_ tokens: [String]) -> Bool {
        // Server options outside this recognized list stay comparison-only.
        var i = 0
        while i < tokens.count {
            if tokens[i].uppercased() == "DEFAULT" { i += 1; continue }
            guard ["ENGINE", "CHARSET", "COLLATE", "COMMENT", "ROW_FORMAT", "KEY_BLOCK_SIZE", "STATS_PERSISTENT", "STATS_AUTO_RECALC", "STATS_SAMPLE_PAGES"].contains(tokens[i].uppercased()) else { return false }
            i += 1
            if i < tokens.count, tokens[i] == "=" { i += 1 }
            guard i < tokens.count else { return false }
            i += 1
        }
        return true
    }
}
