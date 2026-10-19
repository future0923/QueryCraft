import Foundation
import Testing
@testable import QueryCraftFeature

struct SchemaComparisonSemanticsTests {
    private func column(_ type: String = "varchar(255)", nullable: Bool = true, defaultValue: String? = nil,
                        collation: String? = "utf8mb4_general_ci", extra: String = "", comment: String = "") -> WorkspaceDatabaseColumn {
        .init(name: "email", type: type, collation: collation, isNullable: nullable, key: "", defaultValue: defaultValue,
              extra: extra, comment: comment)
    }
    private func part(_ definition: String) throws -> MySQLSchemaDefinition.Part {
        try MySQLSchemaDefinition(ddl: "CREATE TABLE `users` (\(definition))").parts[0]
    }
    @Test func catalogComparisonReportsTheActualChangedAttribute() throws {
        let s = column(), t = column("varchar(100)")
        let attrs = SchemaComparisonSemantics.columnAttributes(source: s, target: t,
            sourcePart: try part("`email` varchar(255) DEFAULT NULL"),
            targetPart: try part("`email` varchar(100) DEFAULT NULL"), options: .init())
        #expect(attrs == [.init(key: "type", source: "varchar(255)", target: "varchar(100)")])
    }
    @Test func implicitColumnCollationAndDefaultNullAreNotFalseChanges() throws {
        let attrs = SchemaComparisonSemantics.columnAttributes(source: column(), target: column(),
            sourcePart: try part("`email` varchar(255)"),
            targetPart: try part("`email` varchar(255) COLLATE utf8mb4_general_ci DEFAULT NULL"), options: .init())
        #expect(attrs.isEmpty)
    }
    @Test func actualCollationAndLiteralNullRemainDifferent() throws {
        let attrs = SchemaComparisonSemantics.columnAttributes(source: column(defaultValue: "NULL"),
            target: column(collation: "utf8mb4_bin"), sourcePart: try part("`email` varchar(255) DEFAULT 'NULL'"),
            targetPart: try part("`email` varchar(255) DEFAULT NULL"), options: .init())
        #expect(Set(attrs.map(\.key)) == ["default", "collation"])
        #expect(attrs.first { $0.key == "default" }?.source == "'NULL'")
        #expect(attrs.first { $0.key == "default" }?.target == "NULL")
    }
    @Test func commentOptionOnlyIgnoresComments() throws {
        let s = column(nullable: false, comment: "A"), t = column(comment: "a")
        var options = SchemaComparisonOptions()
        options.ignoresComments = true
        let attrs = SchemaComparisonSemantics.columnAttributes(source: s, target: t, sourcePart: nil, targetPart: nil, options: options)
        #expect(attrs.contains { $0.key == "nullable" })
        #expect(!attrs.contains { $0.key == "comment" })
    }
    @Test func integerWidthComparisonKeepsExplicitWidthsAndZerofill() {
        #expect(SchemaComparisonSemantics.typesEqual("bigint(20) unsigned", "BIGINT UNSIGNED"))
        #expect(!SchemaComparisonSemantics.typesEqual("int(11)", "int(15)"))
        #expect(!SchemaComparisonSemantics.typesEqual("int(8) zerofill", "int(12) zerofill"))
        #expect(!SchemaComparisonSemantics.typesEqual("varchar(8)", "varchar(12)"))
        #expect(!SchemaComparisonSemantics.typesEqual("enum('A')", "enum('a')"))
    }
    @Test func presentationExtraDoesNotHideRealExtraChanges() {
        let attrs = SchemaComparisonSemantics.columnAttributes(source: column(extra: "DEFAULT_GENERATED"), target: column(),
            sourcePart: nil, targetPart: nil, options: .init())
        #expect(attrs.isEmpty)
        #expect(SchemaComparisonSemantics.columnAttributes(source: column(extra: "auto_increment"), target: column(),
            sourcePart: nil, targetPart: nil, options: .init()).contains { $0.key == "extra" })
    }
    @Test func progressIsMonotonicWithInterleavedEndpointEventsAndZeroTables() {
        var progress = SchemaComparisonProgress()
        progress.accept(.init(completed: 2, total: 10, objectName: "source"), side: .source)
        #expect(progress.fraction == nil)
        progress.accept(.init(completed: 1, total: 5, objectName: "target"), side: .target)
        #expect(progress.fraction == 3.0 / 15)
        progress.accept(.init(completed: 1, total: 10), side: .source)
        progress.accept(.init(completed: 4, total: 99), side: .target)
        #expect(progress.fraction == 3.0 / 15)
        #expect(progress.source.objectName == "source")
        #expect(progress.target.objectName == "target")
        progress.accept(.init(completed: 10, total: 10), side: .source)
        progress.accept(.init(completed: 5, total: 5), side: .target)
        #expect(progress.fraction == 1)
        var empty = SchemaComparisonProgress()
        empty.accept(.init(total: 0), side: .source); empty.accept(.init(total: 0), side: .target)
        #expect(empty.fraction == 1)
    }

    @Test func engineUsesCatalogAttributesInsteadOfShowCreatePresentation() throws {
        func snapshot(_ database: String, ddl: String, columns: [WorkspaceDatabaseColumn]) throws -> SchemaComparisonSnapshot {
            .init(database: database, serverID: "server", version: "8.0.46", sqlMode: "", lowerCaseTableNames: 0,
                  objects: [.init(name: "users", ddl: ddl, definition: try .init(ddl: ddl), error: nil, columns: columns)], capturedAt: .now)
        }
        let source = try snapshot("source", ddl: "CREATE TABLE `users` (`email` varchar(255))", columns: [column()])
        let equal = try snapshot("target", ddl: "CREATE TABLE `users` (`email` varchar(255) COLLATE utf8mb4_general_ci DEFAULT NULL)", columns: [column()])
        #expect(try SchemaComparisonEngine.compare(source: source, target: equal).allSatisfy { $0.status == .equal })
        let changed = try snapshot("target", ddl: "CREATE TABLE `users` (`email` varchar(100) DEFAULT NULL)", columns: [column("varchar(100)")])
        let diff = try #require(SchemaComparisonEngine.compare(source: source, target: changed).first)
        #expect(diff.status == .modified)
        #expect(diff.attributes.map(\.key) == ["type"])
        #expect(diff.sourceDDL == source.objects[0].ddl)
        #expect(diff.targetDDL == changed.objects[0].ddl)
    }
}
