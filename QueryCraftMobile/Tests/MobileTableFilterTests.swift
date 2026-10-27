import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

struct MobileTableFilterTests {
    private func condition(_ operation: WorkspaceDatabaseDataFilterOperator, name: String = "value", kind: WorkspaceDatabaseDataFilterColumnKind = .text, value: String = "x%_\\雪", second: String = "") -> WorkspaceDatabaseDataFilterCondition {
        .init(columnName: name, columnKind: kind, operation: operation, value: value, secondValue: second)
    }

    @Test func desktopPredicateKeepsBoundValuesOperatorsAndBooleanLogic() throws {
        let cases: [(WorkspaceDatabaseDataFilterOperator, String, [WorkspaceDatabaseDataCell])] = [
            (.equal, "`value` = ?", [.text("x%_\\雪")]), (.notEqual, "`value` <> ?", [.text("x%_\\雪")]),
            (.contains, "`value` LIKE ? ESCAPE 0x5c", [.text("%x\\%\\_\\\\雪%")]),
            (.startsWith, "`value` LIKE ? ESCAPE 0x5c", [.text("x\\%\\_\\\\雪%")]),
            (.endsWith, "`value` LIKE ? ESCAPE 0x5c", [.text("%x\\%\\_\\\\雪")]),
            (.isNull, "`value` IS NULL", []), (.isNotNull, "`value` IS NOT NULL", [])]
        for (operation, sql, bindings) in cases {
            let result = try MySQLDataFilterPredicate.make(.init(conditions: [condition(operation)]))
            #expect(result.sql == " WHERE (" + sql + ")")
            #expect(result.bindings == bindings)
        }
        for (operation, sql) in [(WorkspaceDatabaseDataFilterOperator.lessThan, "<"), (.lessThanOrEqual, "<="), (.greaterThan, ">"), (.greaterThanOrEqual, ">=")] {
            let result = try MySQLDataFilterPredicate.make(.init(conditions: [condition(operation, kind: .number, value: "9007199254740993")]))
            #expect(result.sql == " WHERE (`value` \(sql) ?)")
            #expect(result.bindings == [.text("9007199254740993")])
        }
        let between = condition(.between, kind: .number, value: "10", second: "20")
        let result = try MySQLDataFilterPredicate.make(.init(logic: .matchAny, conditions: [between, condition(.isNull)]))
        #expect(result.sql == " WHERE (`value` BETWEEN ? AND ?) OR (`value` IS NULL)")
        #expect(result.bindings == [.text("10"), .text("20")])
    }

    @Test func literalPredicatesCannotInjectSQLAndValidateDisabledConditions() throws {
        let text = "' OR 1=1; -- %_\\\u{0}雪"
        let result = try MySQLDataFilterPredicate.make(.init(conditions: [condition(.equal, name: "odd`?column", value: text)]), values: .literals)
        #expect(result.sql.hasPrefix(" WHERE (`odd``?column` = CONVERT(0x"))
        #expect(result.sql.contains(text) == false)
        #expect(result.bindings.isEmpty)
        try MobileSQLReadPolicy.validate("SELECT * FROM `db`.`t?`" + result.sql, backslashEscapes: false)
        let empty = try MySQLDataFilterPredicate.make(.init(conditions: [condition(.equal, value: "")]), values: .literals)
        #expect(empty.sql == " WHERE (`value` = '')")
        var invalid = condition(.equal, kind: .number, value: "1 OR 1=1")
        #expect(throws: (any Error).self) { try MySQLDataFilterPredicate.make(.init(conditions: [invalid])) }
        invalid.isEnabled = false
        #expect(try MySQLDataFilterPredicate.make(.init(conditions: [invalid])).sql.isEmpty)
        #expect(throws: (any Error).self) { try MySQLDataFilterPredicate.make(.init(conditions: [condition(.term, kind: .elasticsearchKeyword)])) }
    }

    @Test func sharedColumnDefaultsAndSelectionKeepMacRules() {
        #expect(WorkspaceSQLDataFilterColumn.menuValues(type: "enum('one','two','a\\'b')", kind: .enumeration) == ["one", "two", "a'b"])
        let original = WorkspaceSQLDataFilterColumn.defaultCondition(name: "flag", type: "tinyint(1)", kind: .boolean)
        #expect(original.value == "0")
        var selected = original
        selected.isEnabled = false; selected.operation = .isNull; selected.secondValue = "old"
        WorkspaceSQLDataFilterColumn.selectColumn(&selected, name: "name", type: "varchar(80)", kind: .text)
        #expect(selected.id == original.id)
        #expect(selected.isEnabled == false)
        #expect(selected.operation == .isNull)
        #expect(selected.value.isEmpty && selected.secondValue.isEmpty)
        selected.operation = .contains
        WorkspaceSQLDataFilterColumn.selectColumn(&selected, name: "score", type: "decimal(12,2)", kind: .number)
        #expect(selected.operation == .equal)
    }

    @MainActor @Test func draftIsIsolatedAndCannotApplyUnknownOrChangedColumns() throws {
        let object = MobileDatabaseObject(database: "db", name: "t", kind: .table, comment: "")
        let columns = [MobileTableColumn(name: "id", type: "int", isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: "")]
        let filter = WorkspaceDatabaseDataFilter(conditions: [condition(.equal, name: "id", kind: .number, value: "1")])
        let draft = MobileTableFilterDraft(object: object, columns: columns, filter: filter)
        draft.filter.conditions[0].value = "2"
        #expect(filter.conditions[0].value == "1")
        #expect(draft.canApply)
        draft.filter.conditions[0].columnName = "missing"
        #expect(draft.canApply == false)
        draft.filter = .empty
        #expect(draft.canApply)
        draft.addCondition()
        #expect(draft.canApply == false)
        draft.filter.conditions[0].isEnabled = false
        #expect(draft.canApply)
    }

    @MainActor @Test func realServerFiltersRowsBeyondFirstPageAndFiltersViews() async throws {
        let config = try configuration(), service = MobileMySQLService()
        let object = MobileDatabaseObject(database: "querycraft_ios_proof", name: "admin_user", kind: .table, comment: "")
        let columns = try await service.columns(configuration: config, object: object)
        let filter = WorkspaceDatabaseDataFilter(conditions: [condition(.greaterThanOrEqual, name: "id", kind: .number, value: "110")])
        let first = try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 3, sortColumn: "id", ascending: false, filter: filter)
        #expect(first.preview.result.rows.compactMap { $0.first ?? nil } == ["120", "119", "118"])
        #expect(first.hasNextPage)
        #expect(first.filter == filter)
        let next = try await service.page(configuration: config, object: object, columns: columns, offset: 3, size: 3, sortColumn: "id", ascending: false, filter: filter)
        #expect(next.preview.result.rows.compactMap { $0.first ?? nil } == ["117", "116", "115"])
        let view = MobileDatabaseObject(database: "querycraft_ios_proof", name: "sample_view", kind: .view, comment: "")
        let viewColumns = try await service.columns(configuration: config, object: view)
        let result = try await service.page(configuration: config, object: view, columns: viewColumns, offset: 0, size: 100, sortColumn: nil, ascending: true,
            filter: .init(conditions: [condition(.equal, name: "id", kind: .number, value: "2")]))
        #expect(result.preview.result.rows == [["2", "second"]])
    }

    @MainActor @Test func realLiteralWildcardNullBlankBinaryAndAnyMatching() async throws {
        let config = try configuration(), service = MobileMySQLService()
        let object = MobileDatabaseObject(database: "querycraft_ios_proof", name: "filter_cases", kind: .table, comment: "")
        let columns = try await service.columns(configuration: config, object: object)
        let cases: [(WorkspaceDatabaseDataFilterCondition, [String])] = [
            (condition(.contains, name: "text_value", value: "%_"), ["1"]),
            (condition(.equal, name: "text_value", value: "' OR 1=1 --"), ["3"]),
            (condition(.equal, name: "odd?", value: "needle"), ["1"]),
            (condition(.isNull, name: "note"), ["1"]),
            (condition(.equal, name: "note", value: ""), ["2"]),
            (condition(.between, name: "score", kind: .number, value: "15", second: "25"), ["2"]),
            (condition(.equal, name: "flag", kind: .boolean, value: "0"), ["2"]),
            (condition(.equal, name: "state", kind: .enumeration, value: "two"), ["2"]),
            (condition(.isNull, name: "bits", kind: .binary), ["2"]),
            (condition(.equal, name: "bits", kind: .binary, value: "A"), ["3"]),
            (condition(.between, name: "happened", kind: .date, value: "2024-02-01", second: "2024-02-10"), ["2"])]
        for (condition, ids) in cases {
            let result = try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 100, sortColumn: nil, ascending: true, filter: .init(conditions: [condition]))
            #expect(result.preview.result.rows.compactMap { $0.first ?? nil } == ids)
        }
        let any = WorkspaceDatabaseDataFilter(logic: .matchAny, conditions: [condition(.isNull, name: "note"), condition(.greaterThanOrEqual, name: "score", kind: .number, value: "20")])
        let all = WorkspaceDatabaseDataFilter(logic: .matchAll, conditions: any.conditions)
        let anyRows = try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 100, sortColumn: nil, ascending: true, filter: any)
        #expect(anyRows.preview.result.rows.count == 3)
        let noRows = try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 100, sortColumn: nil, ascending: true, filter: all)
        #expect(noRows.preview.result.rows.isEmpty)
        #expect(noRows.preview.result.columns.count == columns.count)
        #expect(noRows.preview.result.columnOrigins[0]?.columnName == "id")
    }

    @Test func realLiteralsSurviveSQLModesAndCrossDatabaseNames() async throws {
        let client = MariaDBClient(configuration: try configuration())
        try await client.connect()
        do {
            let predicate = try MySQLDataFilterPredicate.make(.init(conditions: [condition(.equal, name: "text_value", value: "literal%_\\quote'雪")]), values: .literals)
            let sql = "SELECT id FROM `querycraft_ios_proof`.`filter_cases`" + predicate.sql
            for mode in ["", "NO_BACKSLASH_ESCAPES"] {
                _ = try await client.query("SET SESSION sql_mode='\(mode)'")
                try MobileSQLReadPolicy.validate(sql, backslashEscapes: mode.isEmpty)
                #expect(try await client.queryPreview(sql).result.rows == [["1"]])
            }
            let exact = try MySQLDataFilterPredicate.make(.init(conditions: [condition(.equal, name: "id", kind: .number, value: "318987599031067571")]), values: .literals)
            #expect(try await client.queryPreview("SELECT id FROM `querycraft_ios_other`.`epoch_values`" + exact.sql).result.rows == [["318987599031067571"]])
            await client.close()
        } catch { await client.close(); throw error }
    }

    private func configuration() throws -> MobileSQLConfiguration {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init))
        return .init(host: MobileFixtureEndpoint.host, port: port, username: "proof_reader", password: "querycraft-proof-reader", database: "querycraft_ios_proof", tlsMode: .required)
    }
}
