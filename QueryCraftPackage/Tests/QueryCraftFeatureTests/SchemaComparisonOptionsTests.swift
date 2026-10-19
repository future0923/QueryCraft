import Foundation
import Testing
@testable import QueryCraftFeature

struct SchemaComparisonOptionsTests {
    @Test func explicitTableNamesAreExactAndRespectServerCaseRules() {
        var options = SchemaComparisonOptions()
        options.selectedTables = ["orders*", "odd,table", "用户"]
        #expect(options.includes("orders*", caseInsensitive: false))
        #expect(!options.includes("orders_2026", caseInsensitive: false))
        #expect(options.includes("odd,table", caseInsensitive: false))
        options.selectedTables = ["Orders"]
        #expect(!options.includes("orders", caseInsensitive: false))
        #expect(options.includes("orders", caseInsensitive: true))
        options.selectedTables = []
        options.functions = false
        #expect(!options.hasScope && !options.includes("orders", caseInsensitive: true))
    }

    @Test func configurationRetainsExplicitScopeAndDecodesEarlierAllTablesFiles() throws {
        let id = UUID()
        var options = SchemaComparisonOptions()
        options.selectedTables = ["orders", "odd,table"]
        let config = SchemaComparisonConfiguration(source: .init(profileID: id, database: "source"),
            target: .init(profileID: id, database: "target"), options: options)
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(SchemaComparisonConfiguration.self, from: data) == config)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var previousOptions = try #require(object["options"] as? [String: Any])
        previousOptions.removeValue(forKey: "selectedTables")
        object["options"] = previousOptions
        let previous = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(SchemaComparisonConfiguration.self, from: previous).options.selectedTables == nil)
    }

    private func snapshot(_ ddl: String, database: String, extras: [SchemaComparisonSnapshot.Object] = []) throws -> SchemaComparisonSnapshot {
        .init(database: database, serverID: "one", version: "8.4.11", sqlMode: "", lowerCaseTableNames: 0,
              objects: [.init(name: "orders", ddl: ddl, definition: try MySQLSchemaDefinition(ddl: ddl), error: nil)] + extras, capturedAt: .now)
    }

    @Test func tablePatternsAreAnchoredRespectCaseAndApplyExclusionsFirst() {
        var options = SchemaComparisonOptions()
        options.filterSyntax = .wildcard
        options.includedTables = "orders*, users, odd.table"
        options.excludedTables = "orders_archive*"
        #expect(options.includes("orders_2026", caseInsensitive: false))
        #expect(!options.includes("orders_archive_2026", caseInsensitive: false))
        #expect(!options.includes("USERS", caseInsensitive: false))
        #expect(options.includes("USERS", caseInsensitive: true))
        #expect(!options.includes("oddXtable", caseInsensitive: false))
        #expect(options.includes("odd.table", caseInsensitive: false))
        #expect(!options.includes("prefix_users", caseInsensitive: false))
    }

    @Test func ignoringCommentsAppliesToColumnsAndTableOptions() throws {
        let source = try snapshot("CREATE TABLE `orders` (`id` int COMMENT 'source') ENGINE=InnoDB COMMENT='source table'", database: "source")
        let target = try snapshot("CREATE TABLE `orders` (`id` int COMMENT 'target') ENGINE=InnoDB COMMENT='target table'", database: "target")
        let normal = try SchemaComparisonEngine.compare(source: source, target: target)
        #expect(normal.filter { $0.status == .modified }.count == 2)
        let ignored = try SchemaComparisonEngine.compare(source: source, target: target, options: .init(ignoresComments: true))
        #expect(ignored.count == 1 && ignored.first?.status == .equal)
    }

    @Test func ignoringCommentsDoesNotRemoveDefaultStringContents() throws {
        let source = try snapshot("CREATE TABLE `orders` (`note` varchar(80) DEFAULT 'COMMENT A' COMMENT 'one')", database: "source")
        let target = try snapshot("CREATE TABLE `orders` (`note` varchar(80) DEFAULT 'COMMENT B' COMMENT 'two')", database: "target")
        let result = try SchemaComparisonEngine.compare(source: source, target: target, options: .init(ignoresComments: true))
        #expect(result.first?.status == .modified && result.first?.sql == nil)
    }

    @Test func excludedIncompleteObjectsDoNotPoisonSelectedScope() throws {
        let incomplete = SchemaComparisonSnapshot.Object(name: "restricted", ddl: "", definition: nil, error: "denied")
        let source = try snapshot("CREATE TABLE `orders` (`id` int, `note` varchar(100) DEFAULT NULL)", database: "source", extras: [incomplete])
        let target = try snapshot("CREATE TABLE `orders` (`id` int)", database: "target")
        let all = try SchemaComparisonEngine.compare(source: source, target: target)
        #expect(all.compactMap(\.sql).isEmpty)
        let scoped = try SchemaComparisonEngine.compare(source: source, target: target, options: .init(includedTables: "orders"))
        #expect(scoped.allSatisfy { $0.table == "orders" })
        #expect(scoped.compactMap(\.sql).count == 1)
    }

    @Test func objectScopeFiltersResultsWithoutInventingDependencies() throws {
        let source = try snapshot("CREATE TABLE `orders` (`id` int, `note` varchar(100), KEY `idx_note` (`note`))", database: "source")
        let target = try snapshot("CREATE TABLE `orders` (`id` int)", database: "target")
        let options = SchemaComparisonOptions(columns: false, constraints: false, tableOptions: false)
        let result = try SchemaComparisonEngine.compare(source: source, target: target, options: options)
        #expect(result.count == 1 && result.first?.object == "index:idx_note")
        #expect(result.first?.sql == nil)
    }

    @Test func savedConfigurationRoundTripsWithoutAuthentication() throws {
        let id = UUID()
        let config = SchemaComparisonConfiguration(source: .init(profileID: id, database: "dev"),
            target: .init(profileID: id, database: "test"), options: .init(ignoresComments: true, includedTables: "orders*"))
        let data = try JSONEncoder().encode(config)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.lowercased().contains("password") && !text.contains("authentication"))
        #expect(try JSONDecoder().decode(SchemaComparisonConfiguration.self, from: data) == config)
    }

    @Test func atLeastOneObjectKindIsRequired() {
        #expect(!SchemaComparisonOptions(tables: false, views: false, functions: false).hasScope)
        #expect(SchemaComparisonOptions().hasScope)
    }
}

extension SchemaComparisonOptionsTests {
    @Test func regexFiltersRespectPriorityAndCommasInsideQuantifiers() {
        var options = SchemaComparisonOptions()
        options.includedTables = "^user_"
        options.excludedTables = "[a-z]{2,4}_bak$,^user_archive"
        #expect(options.includes("user_live", caseInsensitive: false))
        #expect(!options.includes("user_archive", caseInsensitive: false))
        options.filterPriority = .include
        #expect(options.includes("user_archive", caseInsensitive: false))
        #expect(SchemaComparisonOptions.excludePatterns(options.excludedTables).count == 2)
        options.includedTables = "["
        #expect(options.validationMessage != nil)
        #expect(!options.includes("anything", caseInsensitive: false))
    }
    @Test func olderConfigurationsPreserveWildcardSyntaxAndNewFieldsGetDefaults() throws {
        let data = Data(#"{"includedTables":"orders*","ignoresComments":true}"#.utf8)
        let options = try JSONDecoder().decode(SchemaComparisonOptions.self, from: data)
        #expect(options.filterSyntax == .wildcard)
        #expect(options.includes("orders_2026", caseInsensitive: false))
        #expect(options.functions && options.views && options.primaryKeys && options.foreignKeys)
        #expect(!options.enableRollback && !options.detectRenames)
    }
}
