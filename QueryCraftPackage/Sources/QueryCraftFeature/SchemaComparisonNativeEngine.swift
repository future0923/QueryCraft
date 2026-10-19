import Foundation

/// Native Swift implementation of the reference workbench's structured
/// comparison → selection projection → dependency-ordered forward/reverse plan.
struct SchemaComparisonNativeStatement: Equatable, Sendable {
    var sql: String
    var order: Int
    var table: String
    var compound = false
    var sequence = 0
}
struct SchemaComparisonNativeUnit: Sendable {
    var difference: SchemaComparisonDifference
    var forward: [SchemaComparisonNativeStatement]
    var reverse: [SchemaComparisonNativeStatement]
    var missingRollback: String? = nil
    var sourceMetadata: SchemaEngineJSON = .null
    var targetMetadata: SchemaEngineJSON = .null
}
struct SchemaComparisonNativeDocument: Sendable {
    var units: [SchemaComparisonNativeUnit]
    let options: SchemaComparisonOptions
    let targetDatabase: String
    let dependencies: [String: Set<String>]
    let reverseDependencies: [String: Set<String>]
    let warnings: [String]
    var batchGroups: [String: [String]] = [:]
}
struct SchemaComparisonNativePlan: Sendable {
    let sql: String
    let rollbackSQL: String
    let statements: [String]
    let rollbackStatements: [String]
    let rollbackComplete: Bool
    let missingRollbackObjects: [String]
}
struct SchemaComparisonNativeResult: Sendable {
    let raw: SchemaComparisonNativeDocument
    let differences: [SchemaComparisonDifference]
    let plan: SchemaComparisonNativePlan
}
struct SchemaComparisonNativeEngine: Sendable {
    @concurrent func analyze(source: SchemaComparisonSnapshot, target: SchemaComparisonSnapshot,
                 options: SchemaComparisonOptions, forVerification: Bool = false) async throws -> SchemaComparisonNativeResult {
        guard forVerification || source.serverID != target.serverID || source.matchingKey(source.database) != target.matchingKey(target.database) else { throw SchemaComparisonError.sameDatabase }
        if let message = options.validationMessage { throw SchemaEngineFailure(message) }
        guard source.allowsExport, target.allowsExport, let s = source.engineMetadata, let t = target.engineMetadata else {
            throw SchemaEngineFailure(AppCopy.current.text("结构元数据不完整，请重新读取。", "Schema metadata is incomplete. Read it again."))
        }
        let builder = try SchemaComparisonNativeBuilder(source: source, target: target, options: options)
        var document = try builder.compare(source: s, target: t)
        Self.resolveDependencies(&document)
        let ids = Set(document.units.filter { !$0.forward.isEmpty }.map { $0.difference.id })
        let plan: SchemaComparisonNativePlan
        if document.units.contains(where: { $0.difference.status == .unavailable }) {
            plan = .init(sql: "", rollbackSQL: "", statements: [], rollbackStatements: [], rollbackComplete: false, missingRollbackObjects: [])
        } else { plan = try await self.plan(result: document, selectedIDs: ids, ignoreForeignKeyChecks: false) }
        return .init(raw: document, differences: document.units.map(\.difference), plan: plan)
    }
    @concurrent func plan(result: SchemaComparisonNativeDocument, selectedIDs: Set<String>, ignoreForeignKeyChecks: Bool) async throws -> SchemaComparisonNativePlan {
        let selected = result.units.filter { selectedIDs.contains($0.difference.id) }
        guard selected.allSatisfy({ $0.difference.requiredIDs.isSubset(of: selectedIDs) }) else {
            throw SchemaEngineFailure(AppCopy.current.text("所选变更缺少依赖，请重新选择。", "Selected changes are missing dependencies. Select them again."))
        }
        let missing = selected.compactMap(\.missingRollback)
        let forward = try Self.ordered(selected.flatMap(\.forward), dependencies: result.dependencies)
        let reverse = try Self.ordered(selected.flatMap(\.reverse), dependencies: result.reverseDependencies)
        func statements(_ values: [SchemaComparisonNativeStatement]) -> [String] {
            guard ignoreForeignKeyChecks, !values.isEmpty else { return values.map(\.sql) }
            return ["SET FOREIGN_KEY_CHECKS = 0"] + values.map(\.sql) + ["SET FOREIGN_KEY_CHECKS = 1"]
        }
        func script(_ values: [SchemaComparisonNativeStatement]) -> String {
            let body = Self.script(values, database: result.targetDatabase)
            return ignoreForeignKeyChecks && !values.isEmpty ? "SET FOREIGN_KEY_CHECKS = 0;\n\n" + body + "\nSET FOREIGN_KEY_CHECKS = 1;\n" : body
        }
        return .init(sql: script(forward), rollbackSQL: result.options.enableRollback ? script(reverse) : "",
                     statements: statements(forward), rollbackStatements: result.options.enableRollback ? statements(reverse) : [],
                     rollbackComplete: missing.isEmpty, missingRollbackObjects: missing)
    }
    static func script(_ statements: [SchemaComparisonNativeStatement], database: String? = nil) -> String {
        let header = statements.isEmpty || database?.isEmpty != false ? "" : "USE " + SchemaComparisonDDL.identifier(database!) + ";\n\n"
        return header + statements.map { statement in
            let sql = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            if statement.compound {
                // The wire execution uses the original whole statement. Delimiter
                // directives are only for exported mysql-client scripts.
                var delimiter = "$$"
                while sql.contains(delimiter) { delimiter += "$" }
                return "DELIMITER \(delimiter)\n" + sql.trimmingCharacters(in: CharacterSet(charactersIn: ";")) + delimiter + "\nDELIMITER ;"
            }
            return sql.hasSuffix(";") ? sql : sql + ";"
        }.joined(separator: "\n\n") + (statements.isEmpty ? "" : "\n")
    }
    private static func ordered(_ statements: [SchemaComparisonNativeStatement], dependencies: [String: Set<String>]) throws -> [SchemaComparisonNativeStatement] {
        let tables = Set(statements.map(\.table))
        var rank: [String: Int] = [:], visiting: Set<String> = [], visited: Set<String> = []
        func visit(_ name: String) throws {
            try Task.checkCancellation()
            guard !visited.contains(name), !visiting.contains(name) else { return }
            visiting.insert(name)
            for dependency in (dependencies[name] ?? []).sorted() where tables.contains(dependency) { try visit(dependency) }
            visiting.remove(name); visited.insert(name); rank[name] = rank.count
        }
        for table in tables.sorted() { try visit(table) }
        let merged = mergeAlterStatements(statements)
        return merged.enumerated().sorted { a, b in
            if a.element.order != b.element.order { return a.element.order < b.element.order }
            let direction = a.element.order >= 110 ? -1 : 1
            let ar = (rank[a.element.table] ?? 0) * direction, br = (rank[b.element.table] ?? 0) * direction
            if ar != br { return ar < br }
            if a.element.sequence != b.element.sequence { return a.element.sequence < b.element.sequence }
            return a.offset < b.offset
        }.map(\.element)
    }
    private static func mergeAlterStatements(_ statements: [SchemaComparisonNativeStatement]) -> [SchemaComparisonNativeStatement] {
        var groups: [String: [(Int, SchemaComparisonNativeStatement, String)]] = [:]
        var result: [SchemaComparisonNativeStatement] = []
        for (index, statement) in statements.enumerated() {
            guard (30...50).contains(statement.order), let tokens = try? SchemaComparisonDDL.tokens(statement.sql),
                  tokens.count > 5, tokens[0].keyword == "ALTER", tokens[1].keyword == "TABLE" else { result.append(statement); continue }
            let end = tokens[3].text == "." ? 4 : 2
            let prefix = String(statement.sql[..<tokens[end].range.upperBound])
            let clause = statement.sql[tokens[end].range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            groups[prefix, default: []].append((index, statement, clause))
        }
        for prefix in groups.keys.sorted() {
            let clauses = groups[prefix]!.sorted { $0.1.order == $1.1.order ? $0.0 < $1.0 : $0.1.order < $1.1.order }
            result.append(.init(sql: prefix + "\n  " + clauses.map { $0.2 }.joined(separator: ",\n  "), order: 40, table: clauses[0].1.table))
        }
        return result
    }
    private static func resolveDependencies(_ document: inout SchemaComparisonNativeDocument) {
        // Index/FK additions need new or renamed columns. Column positioning
        // needs preceding new columns. Removals need dependent index/FK drops.
        let units = document.units
        for i in document.units.indices {
            let change = units[i].difference
            var required = change.requiredIDs
            let relevant = units.filter { $0.difference.table == change.table }
            if change.object.hasPrefix("index:") || change.object.hasPrefix("foreignKey:") {
                if change.status != .targetOnly {
                    for column in relevant where column.difference.object.hasPrefix("column:") && (column.difference.status == .added || column.difference.attributes.contains(where: { $0.key == "name" })) {
                        if units[i].forward.contains(where: { $0.sql.contains(SchemaComparisonDDL.identifier(column.difference.objectName ?? "")) }) { required.insert(column.difference.id) }
                    }
                }
            }
            if change.object.hasPrefix("column:"), change.status == .added {
                for column in relevant where column.difference.status == .added && column.difference.object.hasPrefix("column:") && column.difference.id != change.id {
                    if units[i].forward.contains(where: { $0.sql.hasSuffix("AFTER " + SchemaComparisonDDL.identifier(column.difference.objectName ?? "")) }) { required.insert(column.difference.id) }
                }
            }
            if change.object.hasPrefix("column:"), change.status == .targetOnly {
                for dependency in relevant where dependency.difference.object.hasPrefix("index:") || dependency.difference.object.hasPrefix("foreignKey:") {
                    if dependency.difference.status != .added,
                       (dependency.targetMetadata["columns"].array.contains(.string(change.objectName ?? "")) || dependency.targetMetadata["column_pairs"].array.contains(where: { $0.array.first == .string(change.objectName ?? "") })) { required.insert(dependency.difference.id) }
                }
            }
            if change.object != "table" {
                for rename in relevant where rename.difference.object == "table" && rename.difference.attributes.contains(where: { $0.key == "name" }) { required.insert(rename.difference.id) }
            }
            // Creating a view/table with an FK also selects a new dependency.
            if change.status == .added {
                for name in document.dependencies[change.table] ?? [] {
                    for dependency in units where dependency.difference.table == name && dependency.difference.status == .added && dependency.difference.object == "table" { required.insert(dependency.difference.id) }
                }
            }
            if change.object.hasPrefix("foreignKey:"), change.status != .targetOnly {
                let reference = units[i].sourceMetadata["ref_table"].string
                for rename in units where rename.difference.object == "table" && rename.difference.table == reference && rename.difference.attributes.contains(where: { $0.key == "name" }) { required.insert(rename.difference.id) }
            }
            document.units[i].difference.requiredIDs = required
        }
    }
}

private struct SchemaComparisonNativeBuilder {
    let source: SchemaComparisonSnapshot
    let target: SchemaComparisonSnapshot
    let options: SchemaComparisonOptions
    let sourceDDL: [String: SchemaComparisonDDL]
    let targetDDL: [String: SchemaComparisonDDL]
    init(source: SchemaComparisonSnapshot, target: SchemaComparisonSnapshot, options: SchemaComparisonOptions) throws {
        self.source = source; self.target = target; self.options = options
        func definitions(_ snapshot: SchemaComparisonSnapshot) throws -> [String: SchemaComparisonDDL] {
            var result: [String: SchemaComparisonDDL] = [:]
            let wire = snapshot.engineMetadata ?? .null
            let tableNames = Set(wire["tables"].array.filter { !$0["table_type"].string.contains("VIEW") }.map { $0["name"].string })
            for detail in wire["details"].array where tableNames.contains(detail["name"].string) {
                let definition = try SchemaComparisonDDL(detail["ddl"].string, noBackslashEscapes: snapshot.sqlMode.contains("NO_BACKSLASH_ESCAPES"))
                let catalogNames = detail["columns"].array.map { $0["name"].string }
                let definitionNames = definition.clauses.filter { $0.kind == "column" }.map(\.name)
                guard catalogNames.count == definitionNames.count, Set(catalogNames) == Set(definitionNames) else {
                    throw SchemaEngineFailure(detail["name"].string + ": " + AppCopy.current.text("字段目录与 DDL 不一致，请重新读取；不会把缺失元数据当成删除。", "The column catalog disagrees with DDL. Read it again; missing metadata will not become DROP proposals."))
                }
                result[detail["name"].string] = definition
            }
            return result
        }
        sourceDDL = try definitions(source); targetDDL = try definitions(target)
    }
    func compare(source s: SchemaEngineJSON, target t: SchemaEngineJSON) throws -> SchemaComparisonNativeDocument {
        let sourceDetails = Dictionary(uniqueKeysWithValues: s["details"].array.map { ($0["name"].string, $0) })
        let targetDetails = Dictionary(uniqueKeysWithValues: t["details"].array.map { ($0["name"].string, $0) })
        var units: [SchemaComparisonNativeUnit] = [], warnings: [String] = []
        var dependencies = dependencyGraph(s, database: source.database), reverseDependencies = dependencyGraph(t, database: target.database)
        for kind in ["table", "view"] {
            let sourceTables = s["tables"].array.filter { $0["table_type"].string.contains("VIEW") == (kind == "view") }
            let targetTables = t["tables"].array.filter { $0["table_type"].string.contains("VIEW") == (kind == "view") }
            let matches = Self.matches(sourceTables, targetTables, ignoreCase: options.ignoreTableNameCase)
            var pairs = matches.pairs, sourceOnly = matches.sourceOnly, targetOnly = matches.targetOnly
            if kind == "table", options.detectRenames, options.detectTableRenames {
                let candidates = renameCandidates(sourceOnly, targetOnly, sourceDetails, targetDetails)
                for candidate in candidates {
                    let sName = candidate.0["name"].string, tName = candidate.1["name"].string
                    let q = SchemaComparisonDDL.qualified(target.database, tName), desired = SchemaComparisonDDL.qualified(target.database, sName)
                    units.append(unit(table: sName, kind: "table", name: sName, source: candidate.0, target: candidate.1,
                                      sourceDDL: sourceDetails[sName]?["ddl"].string ?? "", targetDDL: targetDetails[tName]?["ddl"].string ?? "",
                                      attributes: [.init(key: "name", source: sName, target: tName)],
                                      forward: [.init(sql: "RENAME TABLE \(q) TO \(desired)", order: 20, table: sName)],
                                      reverse: [.init(sql: "RENAME TABLE \(desired) TO \(q)", order: 95, table: sName)]))
                    sourceOnly.removeAll { $0["name"].string == sName }; targetOnly.removeAll { $0["name"].string == tName }
                    // A renamed table still receives its other structural changes.
                    pairs.append(candidate)
                }
            }
            for object in sourceOnly {
                try Task.checkCancellation()
                let name = object["name"].string, detail = sourceDetails[name] ?? .null
                let create = try createObject(kind: kind, name: name, detail: detail, sourceSide: true)
                let drop = dropObject(kind: kind, name: name, detail: detail)
                units.append(unit(table: name, kind: kind, name: name, source: object, target: .null, sourceDDL: detail["ddl"].string, targetDDL: "", forward: create, reverse: drop))
            }
            for object in targetOnly {
                try Task.checkCancellation()
                let name = object["name"].string, detail = targetDetails[name] ?? .null
                units.append(unit(table: name, kind: kind, name: name, source: .null, target: object, sourceDDL: "", targetDDL: detail["ddl"].string,
                                  forward: dropObject(kind: kind, name: name, detail: detail), reverse: try createObject(kind: kind, name: name, detail: detail, sourceSide: false)))
            }
            for (so, to) in pairs {
                try Task.checkCancellation()
                let name = so["name"].string, targetName = to["name"].string
                let sd = sourceDetails[name] ?? .null, td = targetDetails[targetName] ?? .null
                let actualTarget = units.contains { $0.difference.object == "table" && $0.difference.table == name && $0.difference.status == .modified } ? name : targetName
                if kind == "view" {
                    let sourceDefinition = try normalizedObject(sd["ddl"].string, kind: "VIEW", database: source.database, name: name)
                    let targetDefinition = try normalizedObject(td["ddl"].string, kind: "VIEW", database: target.database, name: targetName)
                    if sourceDefinition != targetDefinition {
                        units.append(unit(table: name, kind: kind, name: name, source: so, target: to, sourceDDL: sd["ddl"].string, targetDDL: td["ddl"].string,
                                          forward: dropObject(kind: kind, name: actualTarget, detail: td) + (try createObject(kind: kind, name: actualTarget, detail: sd, sourceSide: true)),
                                          reverse: dropObject(kind: kind, name: actualTarget, detail: sd) + (try createObject(kind: kind, name: actualTarget, detail: td, sourceSide: false))))
                    } else { units.append(equal(table: name, kind: kind, sourceDDL: sd["ddl"].string, targetDDL: td["ddl"].string)) }
                    continue
                }
                let before = units.count
                units += try columns(table: name, targetName: actualTarget, sourceDetail: sd, targetDetail: td, targetDefinitionName: targetName)
                units += try namedObjects(table: name, targetName: actualTarget, sourceDetail: sd, targetDetail: td, targetDefinitionName: targetName, kind: "index", key: "indexes")
                units += try namedObjects(table: name, targetName: actualTarget, sourceDetail: sd, targetDetail: td, targetDefinitionName: targetName, kind: "foreignKey", key: "foreignKeys")
                units += try namedObjects(table: name, targetName: actualTarget, sourceDetail: sd, targetDetail: td, targetDefinitionName: targetName, kind: "trigger", key: "triggers")
                if options.checks { units += try checkConstraints(table: name, targetName: actualTarget, sourceDetail: sd, targetDetail: td, targetDefinitionName: targetName) }
                if options.tableOptions && !options.ignoresComments && so["comment"].string != to["comment"].string {
                    let q = SchemaComparisonDDL.qualified(target.database, actualTarget)
                    units.append(unit(table: name, kind: "options", name: "comment", source: so["comment"], target: to["comment"], sourceDDL: sd["ddl"].string, targetDDL: td["ddl"].string,
                        attributes: [.init(key: "comment", source: so["comment"].display, target: to["comment"].display)],
                        forward: [.init(sql: "ALTER TABLE \(q) COMMENT = \(Self.literal(so["comment"].string))", order: 60, table: name)],
                        reverse: [.init(sql: "ALTER TABLE \(q) COMMENT = \(Self.literal(to["comment"].string))", order: 60, table: name)]))
                }
                if before == units.count { units.append(equal(table: name, kind: kind, sourceDDL: sd["ddl"].string, targetDDL: td["ddl"].string)) }
            }
        }
        if options.functions {
            let matches = Self.matches(s["functions"].array, t["functions"].array, ignoreCase: false, identity: { $0["functionType"].string + ":" + $0["name"].string })
            for (so, to) in matches.pairs.map({ ($0.0, $0.1) }) + matches.sourceOnly.map({ ($0, .null) }) + matches.targetOnly.map({ (.null, $0) }) {
                let object = so == .null ? to : so, name = object["name"].string, kind = object["functionType"].string
                guard ["FUNCTION", "PROCEDURE"].contains(kind) else { continue }
                let sd = so["definition"].string, td = to["definition"].string
                let definitionsDiffer = try normalizedObject(sd, kind: kind, database: source.database, name: name) != normalizedObject(td, kind: kind, database: target.database, name: name)
                let changed = so == .null || to == .null || !SchemaComparisonSemantics.typesEqual(so["dataType"].string, to["dataType"].string) || definitionsDiffer
                let table = name + "(" + object["arguments"].string + ")"
                if !changed { units.append(equal(table: table, kind: "function", sourceDDL: sd, targetDDL: td, routineType: kind, routineName: name)); continue }
                let q = SchemaComparisonDDL.qualified(target.database, name)
                func statements(_ ddl: String, exists: Bool, sourceSide: Bool) throws -> [SchemaComparisonNativeStatement] {
                    var result = exists ? [SchemaComparisonNativeStatement(sql: "DROP \(kind) IF EXISTS \(q)", order: 4, table: table)] : []
                    if !ddl.isEmpty { let retargeted = try SchemaComparisonDDL.retarget(ddl, kind: kind, database: target.database, name: name)
                        let rewritten = try replaceDatabaseReferences(retargeted, from: sourceSide ? source.database : target.database, to: target.database)
                        result.append(.init(sql: rewritten, order: 90, table: table, compound: true)) }
                    return result
                }
                units.append(unit(table: table, kind: "function", name: name, source: so, target: to, sourceDDL: sd, targetDDL: td,
                                  forward: try statements(sd, exists: to != .null, sourceSide: true), reverse: try statements(td, exists: so != .null, sourceSide: false)))
            }
        }
        dependencies.merge(dependencyGraph(t, database: target.database)) { $0.union($1) }
        reverseDependencies.merge(dependencyGraph(s, database: source.database)) { $0.union($1) }
        linkAutoIncrementDependencies(for: &units, sourceDetails: sourceDetails, targetDetails: targetDetails)
        try rebuildForeignKeys(for: &units, sourceDetails: sourceDetails, targetDetails: targetDetails)
        try rebuildTriggerGroups(for: &units, sourceDetails: sourceDetails, targetDetails: targetDetails)
        for unit in units where unit.difference.object.hasPrefix("column:") && unit.difference.status == .modified && unit.difference.attributes.contains(where: { $0.key == "type" }) {
            let score = Self.typeSimilarity(unit.sourceMetadata["data_type"].string, unit.targetMetadata["data_type"].string)
            if score < options.compatibilityThreshold {
                warnings.append(unit.difference.table + "." + unit.difference.displayName + ": " + AppCopy.current.text("类型兼容性低于阈值，可能需要数据转换。", "Type compatibility is below the threshold; data conversion may be required."))
            }
        }
        if !MySQLSchemaCompatibility.modesAgree(source.sqlMode, target.sqlMode) {
            warnings.append(AppCopy.current.text("两端 SQL 模式不同，请核对默认值、转义与严格模式。", "SQL modes differ. Review defaults, escaping and strict-mode behavior."))
        }
        if source.version.split(separator: ".").prefix(2) != target.version.split(separator: ".").prefix(2) {
            warnings.append(AppCopy.current.text("正在跨版本比较，请在部署前审核目标服务器的语法兼容性。", "Comparing across versions. Review target-server syntax compatibility before deployment."))
        }
        dependencies.merge(dependencyGraph(s, database: source.database)) { $0.union($1) }
        var document = SchemaComparisonNativeDocument(units: units, options: options, targetDatabase: target.database, dependencies: dependencies, reverseDependencies: reverseDependencies, warnings: warnings)
        let patterns = options.batchPatterns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for pattern in patterns {
            let regex = "^" + pattern.map { $0 == "*" ? ".*" : $0 == "?" ? "." : NSRegularExpression.escapedPattern(for: String($0)) }.joined() + "$"
            let names = Set(units.map { $0.difference.table }).sorted().filter { $0.range(of: regex, options: .regularExpression) != nil }
            if !names.isEmpty { document.batchGroups[pattern] = names }
        }
        return document
    }
    private func linkAutoIncrementDependencies(for units: inout [SchemaComparisonNativeUnit], sourceDetails: [String: SchemaEngineJSON], targetDetails: [String: SchemaEngineJSON]) {
        for table in sourceDetails.keys.sorted() {
            guard let sourceDetail = sourceDetails[table], let targetDetail = targetDetails[table] else { continue }
            let sourceColumns = sourceDetail["columns"].array, targetColumns = targetDetail["columns"].array
            let sourceIndexes = sourceDetail["indexes"].array, targetIndexes = targetDetail["indexes"].array
            func isAuto(_ column: SchemaEngineJSON) -> Bool { column["extra"].string.localizedCaseInsensitiveContains("auto_increment") }
            func leads(_ index: SchemaEngineJSON, column: String) -> Bool { index["columns"].array.first?.string.caseInsensitiveCompare(column) == .orderedSame }
            func fail(_ index: Int) {
                units[index].difference.status = .unavailable
                units[index].difference.explanation = AppCopy.current.text("自增字段与索引存在依赖，请同时启用相关字段和主键/索引比较。", "AUTO_INCREMENT depends on a key. Enable the related column and primary-key/index comparisons together.")
                units[index].difference.reviewSQL = nil; units[index].forward = []; units[index].reverse = []
            }
            for column in sourceColumns where isAuto(column) {
                let name = column["name"].string
                let existing = targetColumns.first { $0["name"].string.caseInsensitiveCompare(name) == .orderedSame }
                guard existing.map(isAuto) != true, !targetIndexes.contains(where: { leads($0, column: existing?["name"].string ?? name) }),
                      let change = units.firstIndex(where: { $0.difference.table == table && $0.difference.object.hasPrefix("column:") && $0.sourceMetadata["name"].string == name }) else { continue }
                let keys = sourceIndexes.filter { leads($0, column: name) }.sorted { $0["is_primary"] == .bool(true) && $1["is_primary"] != .bool(true) }
                if let key = keys.compactMap({ key in units.first(where: { $0.difference.table == table && $0.difference.object == "index:" + key["name"].string }) }).first {
                    units[change].difference.requiredIDs.insert(key.difference.id)
                } else { fail(change) }
            }
            for key in sourceIndexes where key["is_primary"] == .bool(true) {
                guard let primary = units.firstIndex(where: { $0.difference.table == table && $0.difference.object == "index:" + key["name"].string }) else { continue }
                for name in key["columns"].array.map(\.string) {
                    guard targetColumns.first(where: { $0["name"].string == name })?["is_nullable"] == .bool(true) else { continue }
                    if let column = units.first(where: { $0.difference.table == table && $0.difference.object.hasPrefix("column:") && $0.sourceMetadata["name"].string == name }) {
                        units[primary].difference.requiredIDs.insert(column.difference.id)
                    } else if options.enableRollback {
                        fail(primary)
                        units[primary].difference.explanation = AppCopy.current.text("主键会改变字段的 NULL 约束；生成完整回退计划需要同时启用字段比较。", "A primary key changes column nullability. Enable column comparison to generate a complete rollback plan.")
                    }
                }
            }
            for column in targetColumns where isAuto(column) {
                let name = column["name"].string
                let goal = sourceColumns.first { $0["name"].string.caseInsensitiveCompare(name) == .orderedSame }
                let backing = targetIndexes.filter { leads($0, column: name) }
                for key in backing {
                    guard let drop = units.firstIndex(where: { $0.difference.table == table && $0.difference.object == "index:" + key["name"].string && $0.difference.status != .added }) else { continue }
                    if let goal, isAuto(goal) {
                        if leads(units[drop].sourceMetadata, column: name) { continue }
                        let retained = backing.contains { candidate in
                            let sourceKey = sourceIndexes.first { $0["name"] == candidate["name"] }
                            return sourceKey.map { leads($0, column: name) } == true
                        }
                        if retained { continue }
                        if let replacement = units.first(where: { $0.difference.table == table && $0.difference.object.hasPrefix("index:") && leads($0.sourceMetadata, column: name) }) {
                            units[drop].difference.requiredIDs.insert(replacement.difference.id)
                        } else { fail(drop) }
                    } else if let modification = units.first(where: { $0.difference.table == table && $0.difference.object.hasPrefix("column:") && $0.targetMetadata["name"].string == name }) {
                        units[drop].difference.requiredIDs.insert(modification.difference.id)
                    } else { fail(drop) }
                }
            }
        }
    }

    private func rebuildTriggerGroups(for units: inout [SchemaComparisonNativeUnit], sourceDetails: [String: SchemaEngineJSON], targetDetails: [String: SchemaEngineJSON]) throws {
        guard options.triggers else { return }
        let renamed = Dictionary(uniqueKeysWithValues: units.filter { $0.difference.object == "table" && $0.difference.attributes.contains(where: { $0.key == "name" }) }.map { ($0.difference.table, $0.difference.attributes.first { $0.key == "name" }!.target) })
        func group(_ value: SchemaEngineJSON) -> String { value["timing"].string + ":" + value["event"].string }
        for table in sourceDetails.keys.sorted() {
            let targetName = renamed[table] ?? table
            guard let sd = sourceDetails[table], let td = targetDetails[targetName] else { continue }
            let sourceTriggers = sd["triggers"].array, targetTriggers = td["triggers"].array
            for key in Set((sourceTriggers + targetTriggers).map(group)).sorted() {
                let ss = sourceTriggers.filter { group($0) == key }, tt = targetTriggers.filter { group($0) == key }
                guard max(ss.count, tt.count) > 1, units.contains(where: { $0.difference.table == table && $0.difference.object.hasPrefix("trigger:") && (group($0.sourceMetadata) == key || group($0.targetMetadata) == key) }) else { continue }
                let names = Set(ss.map { $0["name"].string } + tt.map { $0["name"].string })
                var ids: Set<String> = []
                for name in names.sorted() {
                    if let existing = units.first(where: { $0.difference.table == table && $0.difference.object == "trigger:" + name }) { ids.insert(existing.difference.id); continue }
                    let s = ss.first { $0["name"].string == name } ?? .null, t = tt.first { $0["name"].string == name } ?? .null
                    var forward: [SchemaComparisonNativeStatement] = [], reverse: [SchemaComparisonNativeStatement] = []
                    if t != .null { forward.append(dropChild(kind: "trigger", name: name, table: table, displayTable: table, current: t)) }
                    if s != .null { forward.append(try createChild(kind: "trigger", value: s, table: table, displayTable: table, definitionName: table, sourceSide: true)) }
                    if s != .null { reverse.append(dropChild(kind: "trigger", name: name, table: table, displayTable: table, current: s)) }
                    if t != .null { reverse.append(try createChild(kind: "trigger", value: t, table: table, displayTable: table, definitionName: targetName, sourceSide: false)) }
                    let change = unit(table: table, kind: "trigger", name: name, source: s, target: t, sourceDDL: sd["ddl"].string, targetDDL: td["ddl"].string,
                        attributes: [.init(key: "dependency", source: AppCopy.current.text("保持源端触发顺序", "Preserve source trigger order"), target: AppCopy.current.text("同时重建同组触发器", "Rebuild the trigger group together"))], forward: forward, reverse: reverse)
                    ids.insert(change.difference.id); units.append(change)
                }
                for index in units.indices where ids.contains(units[index].difference.id) { units[index].difference.requiredIDs.formUnion(ids.subtracting([units[index].difference.id])) }
            }
        }
    }

    private func rebuildForeignKeys(for units: inout [SchemaComparisonNativeUnit], sourceDetails: [String: SchemaEngineJSON], targetDetails: [String: SchemaEngineJSON]) throws {
        let renamedTables = Dictionary(uniqueKeysWithValues: units.filter { $0.difference.object == "table" && $0.difference.attributes.contains(where: { $0.key == "name" }) }.map { ($0.difference.attributes.first { $0.key == "name" }!.target, $0.difference.table) })
        let columnChanges = units.filter { $0.difference.object.hasPrefix("column:") && ($0.difference.status == .targetOnly || $0.difference.attributes.contains { ["type", "generated", "name"].contains($0.key) }) }
        for targetName in targetDetails.keys.sorted() {
            let table = renamedTables[targetName] ?? targetName
            let detail = targetDetails[targetName]!
            for fk in Self.groupForeignKeys(detail["foreignKeys"].array) {
                let ownColumns = Set(fk["column_pairs"].array.compactMap { $0.array.first?.string })
                let refColumns = Set(fk["column_pairs"].array.compactMap { $0.array.last?.string })
                let localReference = fk["ref_schema"].string.isEmpty || fk["ref_schema"].string == target.database
                let reference = renamedTables[fk["ref_table"].string] ?? fk["ref_table"].string
                let changes = columnChanges.filter { change in
                    let oldName = change.targetMetadata["name"].string
                    return change.difference.table == table && ownColumns.contains(oldName)
                        || localReference && change.difference.table == reference && refColumns.contains(oldName)
                }
                guard !changes.isEmpty else { continue }
                guard options.foreignKeys else {
                    throw SchemaEngineFailure(table + "." + fk["name"].string + ": " + AppCopy.current.text("字段变更需要处理已有外键，请启用外键比较。", "Column changes affect an existing foreign key. Enable foreign-key comparison."))
                }
                let name = fk["name"].string
                let id: String
                if let existing = units.firstIndex(where: { $0.difference.table == table && $0.difference.object == "foreignKey:" + name }) {
                    id = units[existing].difference.id
                    if units[existing].sourceMetadata != .null { units[existing].difference.requiredIDs.formUnion(changes.map { $0.difference.id }) }
                } else {
                    guard let desired = Self.groupForeignKeys(sourceDetails[table]?["foreignKeys"].array ?? []).first(where: { $0["name"].string == name }) else { continue }
                    let forward = [dropChild(kind: "foreignKey", name: name, table: table, displayTable: table, current: fk), try createChild(kind: "foreignKey", value: desired, table: table, displayTable: table, definitionName: table, sourceSide: true)]
                    let reverse = [dropChild(kind: "foreignKey", name: name, table: table, displayTable: table, current: desired), try createChild(kind: "foreignKey", value: fk, table: targetName, displayTable: table, definitionName: targetName, sourceSide: false)]
                    var rebuild = unit(table: table, kind: "foreignKey", name: name, source: desired, target: fk,
                        sourceDDL: sourceDetails[table]?["ddl"].string ?? "", targetDDL: detail["ddl"].string,
                        attributes: [.init(key: "dependency", source: AppCopy.current.text("字段变更后恢复外键", "Restore after column changes"), target: AppCopy.current.text("变更前暂时移除外键", "Temporarily drop before column changes"))], forward: forward, reverse: reverse)
                    rebuild.difference.requiredIDs = Set(changes.map { $0.difference.id }); id = rebuild.difference.id
                    units.append(rebuild)
                }
                for index in units.indices where changes.contains(where: { $0.difference.id == units[index].difference.id }) { units[index].difference.requiredIDs.insert(id) }
            }
        }
    }

    private func columns(table: String, targetName: String, sourceDetail: SchemaEngineJSON, targetDetail: SchemaEngineJSON, targetDefinitionName: String) throws -> [SchemaComparisonNativeUnit] {
        guard options.tables, options.columns else { return [] }
        let sc = sourceDetail["columns"].array, tc = targetDetail["columns"].array
        let matched = Self.matches(sc, tc, ignoreCase: options.ignoreColumnNameCase)
        var result: [SchemaComparisonNativeUnit] = []
        let q = SchemaComparisonDDL.qualified(target.database, targetName)
        let sd = sourceDDL[table], td = targetDDL[targetDefinitionName]
        let sText = sourceDetail["ddl"].string, tText = targetDetail["ddl"].string
        let compareOrder = options.compareColumnOrder && sc.count == tc.count && matched.pairs.count == sc.count
        func position(_ columns: [SchemaEngineJSON], _ name: String) -> String {
            guard let index = columns.firstIndex(where: { $0["name"].string == name }) else { return "" }
            return index == 0 ? " FIRST" : " AFTER " + SchemaComparisonDDL.identifier(columns[index - 1]["name"].string)
        }
        func definition(_ name: String, _ column: SchemaEngineJSON, _ ddl: SchemaComparisonDDL?) throws -> String {
            guard let original = ddl?.clause("column", name) else { throw SchemaEngineFailure("\(table).\(name): " + AppCopy.current.text("原始字段定义缺失。", "Original column definition is missing.")) }
            guard options.compareCharset, !column["character_set"].string.isEmpty,
                  !(try SchemaComparisonDDL.tokens(original)).contains(where: { $0.keyword == "CHARACTER" || $0.keyword == "COLLATE" }) else { return original }
            let tokens = try SchemaComparisonDDL.tokens(original)
            var depth = 0
            for token in tokens.dropFirst() {
                if token.text == "(" { depth += 1 }; if token.text == ")" { depth -= 1 }
                if depth == 0 && ["NULL", "NOT", "DEFAULT", "COMMENT", "GENERATED", "AS", "AUTO_INCREMENT", "ON", "INVISIBLE", "VISIBLE"].contains(token.keyword) {
                    let charset = "CHARACTER SET " + SchemaComparisonDDL.identifier(column["character_set"].string) + (column["collation"].string.isEmpty ? "" : " COLLATE " + SchemaComparisonDDL.identifier(column["collation"].string))
                    return String(original[..<token.range.lowerBound]) + charset + " " + original[token.range.lowerBound...]
                }
            }
            return original + " CHARACTER SET " + SchemaComparisonDDL.identifier(column["character_set"].string) + (column["collation"].string.isEmpty ? "" : " COLLATE " + SchemaComparisonDDL.identifier(column["collation"].string))
        }
        for (s, t) in matched.pairs {
            let name = s["name"].string
            var attrs: [SchemaComparisonAttribute] = []
            for (key, label) in [("data_type", "type"), ("is_nullable", "nullable"), ("column_default", "default"), ("character_set", "character_set"), ("collation", "collation"), ("comment", "comment"), ("extra", "extra"), ("generation_expression", "generated")] {
                if key == "comment" && options.ignoresComments || ["character_set", "collation"].contains(key) && !options.compareCharset { continue }
                let a = s[key], b = t[key]
                let same: Bool
                if key == "data_type" { same = SchemaComparisonSemantics.typesEqual(a.string, b.string) }
                else if key == "extra" { same = Self.normalizedExtra(a.string) == Self.normalizedExtra(b.string) }
                else if key == "column_default" { same = Self.normalizedDefault(a, type: s["data_type"].string) == Self.normalizedDefault(b, type: t["data_type"].string) }
                else if ["character_set", "collation"].contains(key) { same = a.string.caseInsensitiveCompare(b.string) == .orderedSame }
                else { same = a == b || a.string.isEmpty && b.string.isEmpty && a.dictionary.isEmpty && b.dictionary.isEmpty && a.array.isEmpty && b.array.isEmpty && key == "comment" }
                if !same { attrs.append(.init(key: label, source: a.display, target: b.display)) }
            }
            let si = sc.firstIndex(of: s) ?? 0, ti = tc.firstIndex(of: t) ?? 0
            if compareOrder, si != ti { attrs.append(.init(key: "order", source: String(si + 1), target: String(ti + 1))) }
            if !attrs.isEmpty {
                result.append(unit(table: table, kind: "column", name: name, source: s, target: t, sourceDDL: sText, targetDDL: tText, attributes: attrs,
                    forward: [.init(sql: "ALTER TABLE \(q) MODIFY COLUMN " + (try definition(name, s, sd)) + (compareOrder ? position(sc, name) : ""), order: 40, table: table)],
                    reverse: [.init(sql: "ALTER TABLE \(q) MODIFY COLUMN " + (try definition(t["name"].string, t, td)) + (compareOrder ? position(tc, t["name"].string) : ""), order: 40, table: table)]))
            }
        }
        var added = matched.sourceOnly, removed = matched.targetOnly
        if options.detectRenames, options.renameThreshold > 0 {
            for old in matched.targetOnly {
                var best: SchemaEngineJSON?, bestScore = 0.0
                for new in added {
                    let similarity = Self.typeSimilarity(old["data_type"].string, new["data_type"].string)
                    guard similarity >= options.renameThreshold else { continue }
                    let score = similarity * (old["is_nullable"] == new["is_nullable"] ? 1 : 0.8)
                    if score > bestScore { best = new; bestScore = score }
                }
                if let new = best {
                    let oldName = old["name"].string, name = new["name"].string
                    result.append(unit(table: table, kind: "column", name: name, source: new, target: old, sourceDDL: sText, targetDDL: tText,
                        attributes: [.init(key: "name", source: name, target: oldName)],
                        forward: [.init(sql: "ALTER TABLE \(q) CHANGE COLUMN \(SchemaComparisonDDL.identifier(oldName)) " + (try definition(name, new, sd)), order: 40, table: table)],
                        reverse: [.init(sql: "ALTER TABLE \(q) CHANGE COLUMN \(SchemaComparisonDDL.identifier(name)) " + (try definition(oldName, old, td)), order: 40, table: table)]))
                    added.removeAll { $0 == new }; removed.removeAll { $0 == old }
                }
            }
        }
        for column in added {
            let name = column["name"].string
            result.append(unit(table: table, kind: "column", name: name, source: column, target: .null, sourceDDL: sText, targetDDL: tText,
                forward: [.init(sql: "ALTER TABLE \(q) ADD COLUMN " + (try definition(name, column, sd)) + position(sc, name), order: 40, table: table)],
                reverse: [.init(sql: "ALTER TABLE \(q) DROP COLUMN \(SchemaComparisonDDL.identifier(name))", order: 40, table: table)]))
        }
        for column in removed {
            let name = column["name"].string
            result.append(unit(table: table, kind: "column", name: name, source: .null, target: column, sourceDDL: sText, targetDDL: tText,
                forward: [.init(sql: "ALTER TABLE \(q) DROP COLUMN \(SchemaComparisonDDL.identifier(name))", order: 40, table: table)],
                reverse: [.init(sql: "ALTER TABLE \(q) ADD COLUMN " + (try definition(name, column, td)) + position(tc, name), order: 40, table: table)]))
        }
        return result
    }
    private func namedObjects(table: String, targetName: String, sourceDetail: SchemaEngineJSON, targetDetail: SchemaEngineJSON, targetDefinitionName: String, kind: String, key: String) throws -> [SchemaComparisonNativeUnit] {
        func filtered(_ rows: [SchemaEngineJSON]) -> [SchemaEngineJSON] {
            if kind == "foreignKey" { return options.foreignKeys ? Self.groupForeignKeys(rows) : [] }
            if kind == "trigger" { return options.triggers ? rows : [] }
            return rows.filter { $0["is_primary"] == .bool(true) ? options.primaryKeys : $0["is_unique"] == .bool(true) ? options.uniqueKeys : options.indexes }
        }
        let matches = Self.matches(filtered(sourceDetail[key].array), filtered(targetDetail[key].array), ignoreCase: false)
        var result: [SchemaComparisonNativeUnit] = []
        for (s, t) in matches.pairs + matches.sourceOnly.map({ ($0, .null) }) + matches.targetOnly.map({ (.null, $0) }) {
            let value = s == .null ? t : s, name = value["name"].string
            let keys: [String] = kind == "index" ? ["columns", "is_unique", "is_primary", "index_type", "filter", "included_columns", "column_opclasses", "key_options"] : kind == "foreignKey" ? ["column_pairs", "ref_schema", "ref_table", "on_delete", "on_update"] : ["event", "timing", "statement", "action_order"]
            func normalized(_ v: SchemaEngineJSON, key: String, sourceSide: Bool) -> SchemaEngineJSON {
                if v == .null { return .null }
                let value = v[key]
                if kind == "foreignKey", key == "ref_schema", value.string == (sourceSide ? source.database : target.database) { return .string("<current>") }
                if key == "statement" {
                    let rewritten = (try? replaceDatabaseReferences(value.string, from: sourceSide ? source.database : target.database, to: "<database>")) ?? value.string
                    return .array(SchemaComparisonDDL.canonical(rewritten).map(SchemaEngineJSON.string))
                }
                if options.ignoreColumnNameCase && ["columns", "included_columns"].contains(key) { return .array(value.array.map { .string($0.string.lowercased()) }) }
                if ["is_unique", "is_primary"].contains(key) { return value }
                if value == .null || value == .string("") || value == .array([]) { return .null }
                return value
            }
            var attrs = keys.filter { normalized(s, key: $0, sourceSide: true) != normalized(t, key: $0, sourceSide: false) }.map { SchemaComparisonAttribute(key: $0, source: s[$0].display, target: t[$0].display) }
            if kind == "index", s != .null, t != .null,
               let sourceClause = sourceDDL[table]?.clause("index", name), let targetClause = targetDDL[targetDefinitionName]?.clause("index", name) {
                var st = SchemaComparisonDDL.canonical(sourceClause), tt = SchemaComparisonDDL.canonical(targetClause)
                if options.ignoreColumnNameCase { st = st.map { $0.hasPrefix("`") ? $0.lowercased() : $0 }; tt = tt.map { $0.hasPrefix("`") ? $0.lowercased() : $0 } }
                if options.ignoresComments {
                    if let i = st.firstIndex(of: "COMMENT"), st.indices.contains(i+1) { st.removeSubrange(i...i+1) }
                    if let i = tt.firstIndex(of: "COMMENT"), tt.indices.contains(i+1) { tt.removeSubrange(i...i+1) }
                }
                if st != tt { attrs.append(.init(key: "definition", source: sourceClause, target: targetClause)) }
            }
            if s != .null, t != .null, attrs.isEmpty { continue }
            func statements(_ desired: SchemaEngineJSON, _ current: SchemaEngineJSON, _ sourceSide: Bool) throws -> [SchemaComparisonNativeStatement] {
                var result: [SchemaComparisonNativeStatement] = []
                if current != .null { result.append(dropChild(kind: kind, name: name, table: targetName, displayTable: table, current: current)) }
                if desired != .null { result.append(try createChild(kind: kind, value: desired, table: !sourceSide && kind == "foreignKey" ? targetDefinitionName : targetName, displayTable: table, definitionName: sourceSide ? table : targetDefinitionName, sourceSide: sourceSide)) }
                return result
            }
            result.append(unit(table: table, kind: kind, name: name, source: s, target: t, sourceDDL: sourceDetail["ddl"].string, targetDDL: targetDetail["ddl"].string, attributes: attrs,
                               forward: try statements(s, t, true), reverse: try statements(t, s, false)))
        }
        return result
    }
    private func checkConstraints(table: String, targetName: String, sourceDetail: SchemaEngineJSON, targetDetail: SchemaEngineJSON, targetDefinitionName: String) throws -> [SchemaComparisonNativeUnit] {
        let sc = sourceDDL[table]?.clauses.filter { $0.kind == "check" } ?? [], tc = targetDDL[targetDefinitionName]?.clauses.filter { $0.kind == "check" } ?? []
        let names = Set(sc.map(\.name)).union(tc.map(\.name))
        let q = SchemaComparisonDDL.qualified(target.database, targetName)
        return names.sorted().compactMap { name in
            let s = sc.first { $0.name == name }, t = tc.first { $0.name == name }
            if s?.sql == t?.sql { return nil }
            func statements(_ desired: SchemaComparisonDDL.Clause?, _ current: SchemaComparisonDDL.Clause?) -> [SchemaComparisonNativeStatement] {
                var result: [SchemaComparisonNativeStatement] = []
                if current != nil { result.append(.init(sql: "ALTER TABLE \(q) DROP CHECK \(SchemaComparisonDDL.identifier(name))", order: 10, table: table)) }
                if let desired { result.append(.init(sql: "ALTER TABLE \(q) ADD " + desired.sql, order: 60, table: table)) }
                return result
            }
            return unit(table: table, kind: "constraint", name: name, source: s.map { .string($0.sql) } ?? .null, target: t.map { .string($0.sql) } ?? .null,
                        sourceDDL: sourceDetail["ddl"].string, targetDDL: targetDetail["ddl"].string,
                        forward: statements(s, t), reverse: statements(t, s))
        }
    }
    private func createChild(kind: String, value: SchemaEngineJSON, table: String, displayTable: String, definitionName: String, sourceSide: Bool) throws -> SchemaComparisonNativeStatement {
        let q = SchemaComparisonDDL.qualified(target.database, table), name = value["name"].string
        let definition = (sourceSide ? sourceDDL : targetDDL)[definitionName]
        if kind == "index" {
            guard let clause = definition?.clause("index", name) else { throw SchemaEngineFailure("\(table).\(name): missing index definition") }
            return .init(sql: "ALTER TABLE \(q) ADD " + clause, order: 50, table: displayTable)
        }
        if kind == "foreignKey" {
            let pairs = value["column_pairs"].array
            let columns = pairs.map { SchemaComparisonDDL.identifier($0.array.first?.string ?? "") }.joined(separator: ", ")
            let refColumns = pairs.map { SchemaComparisonDDL.identifier($0.array.last?.string ?? "") }.joined(separator: ", ")
            let originalDatabase = sourceSide ? source.database : target.database
            let refDatabase = value["ref_schema"].string.isEmpty || value["ref_schema"].string == originalDatabase ? target.database : value["ref_schema"].string
            var sql = "ALTER TABLE \(q) ADD CONSTRAINT \(SchemaComparisonDDL.identifier(name)) FOREIGN KEY (\(columns)) REFERENCES \(SchemaComparisonDDL.qualified(refDatabase, value["ref_table"].string)) (\(refColumns))"
            for (key, operation) in [("on_delete", "DELETE"), ("on_update", "UPDATE")] {
                let action = value[key].string.uppercased()
                if ["CASCADE", "SET NULL", "RESTRICT", "NO ACTION", "SET DEFAULT"].contains(action) { sql += " ON \(operation) \(action)" }
            }
            return .init(sql: sql, order: 80, table: displayTable)
        }
        guard !value["statement"].string.isEmpty else { throw SchemaEngineFailure("\(table).\(name): " + AppCopy.current.text("触发器定义缺失。", "Trigger body is missing.")) }
        guard ["BEFORE", "AFTER"].contains(value["timing"].string.uppercased()), ["INSERT", "UPDATE", "DELETE"].contains(value["event"].string.uppercased()) else { throw SchemaComparisonError.invalidDefinition }
        let body = try replaceDatabaseReferences(value["statement"].string, from: sourceSide ? source.database : target.database, to: target.database)
        return .init(sql: "CREATE TRIGGER \(SchemaComparisonDDL.qualified(target.database, name)) \(value["timing"].string) \(value["event"].string) ON \(q) FOR EACH ROW \(body)", order: 90, table: displayTable, compound: true, sequence: Int(value["action_order"].string) ?? 0)
    }
    private func dropChild(kind: String, name: String, table: String, displayTable: String, current: SchemaEngineJSON) -> SchemaComparisonNativeStatement {
        let q = SchemaComparisonDDL.qualified(target.database, table)
        switch kind {
        case "index": return .init(sql: "ALTER TABLE \(q) " + (current["is_primary"] == .bool(true) ? "DROP PRIMARY KEY" : "DROP INDEX " + SchemaComparisonDDL.identifier(name)), order: 30, table: displayTable)
        case "foreignKey": return .init(sql: "ALTER TABLE \(q) DROP FOREIGN KEY \(SchemaComparisonDDL.identifier(name))", order: 10, table: displayTable)
        default: return .init(sql: "DROP TRIGGER IF EXISTS \(SchemaComparisonDDL.qualified(target.database, name))", order: 5, table: displayTable)
        }
    }
    private func createObject(kind: String, name: String, detail: SchemaEngineJSON, sourceSide: Bool) throws -> [SchemaComparisonNativeStatement] {
        if kind == "view" {
            var sql = try SchemaComparisonDDL.retarget(detail["ddl"].string, kind: "VIEW", database: target.database, name: name)
            sql = try replaceDatabaseReferences(sql, from: sourceSide ? source.database : target.database, to: target.database)
            return [.init(sql: sql, order: 100, table: name)]
        }
        guard let definition = (sourceSide ? sourceDDL : targetDDL)[detail["name"].string] else { throw SchemaComparisonError.invalidDefinition }
        var result = [SchemaComparisonNativeStatement(sql: definition.create(database: target.database, name: name, omittingForeignKeys: true), order: 25, table: name)]
        let knownForeignKeys = Self.groupForeignKeys(detail["foreignKeys"].array)
        for fk in definition.clauses where fk.kind == "foreignKey" {
            if let metadata = knownForeignKeys.first(where: { $0["name"].string == fk.name }) {
                result.append(try createChild(kind: "foreignKey", value: metadata, table: name, displayTable: name, definitionName: name, sourceSide: sourceSide))
            } else {
                let clause = try replaceDatabaseReferences(fk.sql, from: sourceSide ? source.database : target.database, to: target.database)
                result.append(.init(sql: "ALTER TABLE \(SchemaComparisonDDL.qualified(target.database, name)) ADD " + clause, order: 80, table: name))
            }
        }
        for trigger in detail["triggers"].array { result.append(try createChild(kind: "trigger", value: trigger, table: name, displayTable: name, definitionName: name, sourceSide: sourceSide)) }
        return result
    }
    private func dropObject(kind: String, name: String, detail: SchemaEngineJSON) -> [SchemaComparisonNativeStatement] {
        var result: [SchemaComparisonNativeStatement] = []
        if kind == "table" {
            for fk in Self.groupForeignKeys(detail["foreignKeys"].array) { result.append(dropChild(kind: "foreignKey", name: fk["name"].string, table: name, displayTable: name, current: fk)) }
        }
        result.append(.init(sql: "DROP \(kind.uppercased()) IF EXISTS \(SchemaComparisonDDL.qualified(target.database, name))", order: kind == "view" ? 0 : 110, table: name))
        return result
    }
    private func unit(table: String, kind: String, name: String, source s: SchemaEngineJSON, target t: SchemaEngineJSON,
                      sourceDDL: String, targetDDL: String, attributes: [SchemaComparisonAttribute] = [],
                      forward: [SchemaComparisonNativeStatement], reverse: [SchemaComparisonNativeStatement]) -> SchemaComparisonNativeUnit {
        let status: SchemaComparisonDifference.Status = s == .null ? .targetOnly : t == .null ? .added : .modified
        let sql = SchemaComparisonNativeEngine.script(forward)
        var attributes = attributes
        if attributes.isEmpty && ["column", "index", "foreignKey", "trigger"].contains(kind) {
            let keys = kind == "column" ? ["data_type", "is_nullable", "column_default", "comment", "extra", "generation_expression"] :
                kind == "index" ? ["columns", "is_unique", "is_primary", "index_type"] :
                kind == "foreignKey" ? ["column_pairs", "ref_schema", "ref_table", "on_delete", "on_update"] : ["event", "timing", "statement"]
            let labels = ["data_type": "type", "is_nullable": "nullable", "column_default": "default", "generation_expression": "generated"]
            attributes = keys.filter { key in
                let value = (s == .null ? t : s)[key]
                return value != .null && value != .string("") || key == "column_default"
            }.map { key in .init(key: labels[key] ?? key, source: s == .null ? "—" : s[key].display, target: t == .null ? "—" : t[key].display) }
        }
        let routineType = kind == "function" ? (s == .null ? t : s)["functionType"].string : ""
        let container = kind == "function" ? "routine:" + routineType + ":" + name : nil
        var difference = SchemaComparisonDifference(id: (container ?? table) + "\0" + kind + ":" + name, table: table,
            object: ["table", "view", "function", "sequence", "rule", "owner"].contains(kind) ? kind : kind + ":" + name,
            status: status, source: s == .null ? "" : s.display, target: t == .null ? "" : t.display,
            sourceDDL: sourceDDL, targetDDL: targetDDL, sql: nil,
            explanation: attributes.map(\.summary).joined(separator: "\n"), routineType: routineType.isEmpty ? nil : routineType, containerID: container, objectName: name, attributes: attributes,
            reviewSQL: sql.isEmpty ? nil : sql)
        difference.isRisky = status == .targetOnly || kind == "column" && status == .modified
            || kind == "column" && status == .added && s["is_nullable"] == .bool(false) && s["column_default"] == .null && !s["extra"].string.localizedCaseInsensitiveContains("auto_increment")
            || sql.localizedCaseInsensitiveContains("DROP ")
        let reverse = reverse.map { statement in
            var statement = statement
            // Restored FK references can use a table's original name after a
            // reverse rename; defer those additions until renames finish.
            if statement.order == 80 { statement.order = 150 }
            return statement
        }
        return .init(difference: difference, forward: forward, reverse: reverse, sourceMetadata: s, targetMetadata: t)
    }
    private func equal(table: String, kind: String, sourceDDL: String, targetDDL: String, routineType: String? = nil, routineName: String? = nil) -> SchemaComparisonNativeUnit {
        let container = routineType.map { "routine:" + $0 + ":" + (routineName ?? table) }
        return .init(difference: .init(id: (container ?? table) + "\0equal", table: table, object: kind, status: .equal, source: sourceDDL, target: targetDDL,
                               sourceDDL: sourceDDL, targetDDL: targetDDL, sql: nil, explanation: AppCopy.current.text("定义一致。", "Definitions match."), routineType: routineType, containerID: container), forward: [], reverse: [])
    }
    private static func matches(_ source: [SchemaEngineJSON], _ target: [SchemaEngineJSON], ignoreCase: Bool,
                                identity: (SchemaEngineJSON) -> String = { $0["name"].string }) -> (pairs: [(SchemaEngineJSON, SchemaEngineJSON)], sourceOnly: [SchemaEngineJSON], targetOnly: [SchemaEngineJSON]) {
        var indices: [Int: Int] = [:], used: Set<Int> = []
        for i in source.indices {
            if let j = target.indices.first(where: { !used.contains($0) && identity(source[i]) == identity(target[$0]) }) { indices[i] = j; used.insert(j) }
        }
        if ignoreCase {
            for i in source.indices where indices[i] == nil {
                let candidates = target.indices.filter { !used.contains($0) && identity(source[i]).caseInsensitiveCompare(identity(target[$0])) == .orderedSame }
                if candidates.count == 1, let j = candidates.first { indices[i] = j; used.insert(j) }
            }
        }
        return (source.indices.compactMap { i in indices[i].map { (source[i], target[$0]) } }, source.indices.filter { indices[$0] == nil }.map { source[$0] }, target.indices.filter { !used.contains($0) }.map { target[$0] })
    }
    private static func groupForeignKeys(_ rows: [SchemaEngineJSON]) -> [SchemaEngineJSON] {
        var names: [String] = [], result: [String: SchemaEngineJSON] = [:]
        for row in rows {
            let name = row["name"].string
            if result[name] == nil { names.append(name); result[name] = row; result[name]?["column_pairs"] = .array([]) }
            let old = result[name]?["column_pairs"].array ?? []
            result[name]?["column_pairs"] = .array(old + [.array([row["column"], row["ref_column"]])])
        }
        return names.compactMap { result[$0] }
    }
    private func dependencyGraph(_ metadata: SchemaEngineJSON, database: String) -> [String: Set<String>] {
        let names = Set(metadata["tables"].array.map { $0["name"].string })
        var result: [String: Set<String>] = [:]
        for detail in metadata["details"].array {
            let name = detail["name"].string
            result[name] = Set(detail["foreignKeys"].array.filter { $0["ref_schema"].string.isEmpty || $0["ref_schema"].string == database }.map { $0["ref_table"].string }).intersection(names).subtracting([name])
            if let definition = try? SchemaComparisonDDL(detail["ddl"].string) {
                for clause in definition.clauses where clause.kind == "foreignKey" {
                    if let tokens = try? SchemaComparisonDDL.tokens(clause.sql), let i = tokens.firstIndex(where: { $0.keyword == "REFERENCES" }), i + 1 < tokens.count {
                        let qualified = i + 3 < tokens.count && tokens[i+2].text == "."
                        if qualified && tokens[i+1].identifier != database { continue }
                        let referenced = qualified ? tokens[i+3].identifier : tokens[i+1].identifier
                        if names.contains(referenced), referenced != name { result[name, default: []].insert(referenced) }
                    }
                }
            }
            if metadata["tables"].array.contains(where: { $0["name"].string == name && $0["table_type"].string.contains("VIEW") }),
               let tokens = try? SchemaComparisonDDL.tokens(detail["ddl"].string) {
                for i in tokens.indices where ["FROM", "JOIN"].contains(tokens[i].keyword) && i + 1 < tokens.count {
                    let qualified = i + 3 < tokens.count && tokens[i + 2].text == "."
                    if qualified && tokens[i+1].identifier != database { continue }
                    let object = qualified ? tokens[i + 3].identifier : tokens[i + 1].identifier
                    if object != name, names.contains(object) { result[name, default: []].insert(object) }
                }
            }
        }
        return result
    }
    private func renameCandidates(_ added: [SchemaEngineJSON], _ removed: [SchemaEngineJSON], _ sourceDetails: [String: SchemaEngineJSON], _ targetDetails: [String: SchemaEngineJSON]) -> [(SchemaEngineJSON, SchemaEngineJSON)] {
        var scores: [(SchemaEngineJSON, SchemaEngineJSON, Double)] = []
        for t in removed {
            for s in added {
                let sc = sourceDetails[s["name"].string]?["columns"].array ?? [], tc = targetDetails[t["name"].string]?["columns"].array ?? []
                let sn = Set(sc.map { $0["name"].string }), tn = Set(tc.map { $0["name"].string })
                let common = sn.intersection(tn), union = sn.union(tn)
                let jaccard = union.isEmpty ? 1 : Double(common.count) / Double(union.count)
                guard jaccard >= options.renameThreshold else { continue }
                let typeScore = common.isEmpty ? 0 : common.reduce(0.0) { total, name in total + Self.typeSimilarity(sc.first { $0["name"].string == name }?["data_type"].string ?? "", tc.first { $0["name"].string == name }?["data_type"].string ?? "") } / Double(common.count)
                let score = jaccard * 0.6 + typeScore * 0.4
                if score >= options.renameThreshold { scores.append((s, t, score)) }
            }
        }
        scores.sort { $0.2 > $1.2 }
        var usedSource: Set<String> = [], usedTarget: Set<String> = []
        return scores.compactMap { s, t, _ in
            guard !usedSource.contains(s["name"].string), !usedTarget.contains(t["name"].string) else { return nil }
            usedSource.insert(s["name"].string); usedTarget.insert(t["name"].string); return (s, t)
        }
    }
    private static func typeSimilarity(_ source: String, _ target: String) -> Double {
        func canonical(_ value: String) -> String {
            let base = value.uppercased().split(separator: "(").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            return ["INTEGER": "INT", "BOOL": "BOOLEAN", "DOUBLE PRECISION": "DOUBLE", "DATETIME": "TIMESTAMP" ][base] ?? base
        }
        let a = canonical(source), b = canonical(target)
        if a == b { return 1 }
        let families = [["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "BIGINT"], ["CHAR", "VARCHAR", "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT", "CLOB"], ["BINARY", "VARBINARY", "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB"], ["DECIMAL", "NUMERIC", "FLOAT", "REAL", "DOUBLE"]]
        return families.contains { $0.contains(a) && $0.contains(b) } ? 0.8 : 0
    }
    private static func normalizedExtra(_ value: String) -> String {
        value.uppercased().replacingOccurrences(of: "CURRENT_TIMESTAMP()", with: "CURRENT_TIMESTAMP").split(whereSeparator: \.isWhitespace).filter { $0 != "DEFAULT_GENERATED" }.joined(separator: " ")
    }
    private static func normalizedDefault(_ value: SchemaEngineJSON, type: String) -> SchemaEngineJSON {
        if ["TIMESTAMP", "DATETIME"].contains(type.uppercased().split(separator: "(").first.map(String.init) ?? ""),
           value.string.range(of: "^CURRENT_TIMESTAMP(?:\\([0-6]?\\))?$", options: [.regularExpression, .caseInsensitive]) != nil {
            return .string(value.string.uppercased().replacingOccurrences(of: "CURRENT_TIMESTAMP()", with: "CURRENT_TIMESTAMP"))
        }
        return value
    }
    private func normalizedObject(_ ddl: String, kind: String, database: String, name: String) throws -> [String] {
        guard !ddl.isEmpty else { return [] }
        var sql = try SchemaComparisonDDL.retarget(ddl, kind: kind, database: "<database>", name: "<object>")
        sql = try replaceDatabaseReferences(sql, from: database, to: "<database>")
        var tokens = try SchemaComparisonDDL.tokens(sql)
        // SHOW CREATE's definer is endpoint-local authentication, not structure.
        if let index = tokens.firstIndex(where: { $0.keyword == "DEFINER" }), index + 4 < tokens.count, tokens[index + 1].text == "=" {
            var end = index + 3
            if tokens[end].text == "@", end + 1 < tokens.count { end += 2 }
            tokens.removeSubrange(index..<end)
        }
        var values = tokens.filter { $0.text != ";" }.map { ["'", "\"", "`"].contains($0.text.first) ? $0.text : $0.keyword }
        var i = 0
        while i + 3 < values.count {
            if ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT"].contains(values[i]),
               values[i+1] == "(", values[i+2].allSatisfy(\.isNumber), values[i+3] == ")",
               !values.dropFirst(i+4).prefix(2).contains("ZEROFILL") { values.removeSubrange((i+1)...(i+3)) }
            i += 1
        }
        return values
    }
    private func replaceDatabaseReferences(_ sql: String, from: String, to: String) throws -> String {
        let tokens = try SchemaComparisonDDL.tokens(sql)
        var replacements: [Range<String.Index>] = []
        var tableLists = [false]
        for i in tokens.indices {
            let token = tokens[i]
            if token.text == "(" { tableLists.append(false) }
            if token.text == ")", tableLists.count > 1 { tableLists.removeLast() }
            if ["FROM", "JOIN", "UPDATE"].contains(token.keyword) { tableLists[tableLists.count-1] = true }
            if ["SELECT", "WHERE", "ON", "SET", "VALUES", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION", ";"].contains(token.keyword) { tableLists[tableLists.count-1] = false }
            guard i + 2 < tokens.count, token.identifier == from, tokens[i+1].text == ".",
                  token.text.first != "'", token.text.first != "\"" else { continue }
            let previous = i > 0 ? tokens[i-1].keyword : ""
            let isThreePartColumn = i + 4 < tokens.count && tokens[i+3].text == "."
            let isRoutineCall = i + 3 < tokens.count && tokens[i+3].text == "("
            let isTablePosition = ["FROM", "JOIN", "INTO", "UPDATE", "REPLACE", "TABLE", "VIEW", "FUNCTION", "PROCEDURE", "TRIGGER", "REFERENCES", "CALL"].contains(previous)
                || previous == "," && tableLists.last == true
            let isIndexTable = previous == "ON" && tokens[max(0,i-7)..<i].contains(where: { $0.keyword == "INDEX" })
            // A two-part column reference may use an alias whose name happens
            // to equal the database. Only rewrite proven relation/routine or
            // three-part database-qualified references, never those aliases.
            if isThreePartColumn || isRoutineCall || isTablePosition || isIndexTable { replacements.append(token.range) }
        }
        var result = sql
        for range in replacements.reversed() { result.replaceSubrange(range, with: SchemaComparisonDDL.identifier(to)) }
        return result
    }
    private static func literal(_ value: String) -> String { SchemaComparisonCatalogLoader.literal(value) }
}
