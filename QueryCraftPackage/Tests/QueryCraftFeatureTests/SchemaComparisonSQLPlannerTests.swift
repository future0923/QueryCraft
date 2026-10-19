import Foundation
import Testing
@testable import QueryCraftFeature

struct SchemaComparisonSQLPlannerTests {
    private func snapshot(_ database: String, _ tables: [(String, String)]) throws -> SchemaComparisonSnapshot {
        .init(database: database, serverID: "server", version: "8.0.46", sqlMode: "", lowerCaseTableNames: 0,
              objects: try tables.map { name, body in
                  let ddl = "CREATE TABLE \(MySQLSchemaDefinition.identifier(name)) (\(body)) ENGINE=InnoDB"
                  return .init(name: name, ddl: ddl, definition: try .init(ddl: ddl), error: nil)
              }, capturedAt: .now)
    }
    @Test func createsModifiesAndDropsQualifiedTargetObjects() throws {
        let source = try snapshot("source", [("orders", "`id` int, `note` varchar(255)"),
                                             ("new_orders", "`id` int NOT NULL AUTO_INCREMENT, PRIMARY KEY (`id`)")])
        let target = try snapshot("target`db", [("orders", "`id` int, `note` varchar(100)"), ("legacy", "`id` int")])
        let result = try SchemaComparisonEngine.compare(source: source, target: target)
        let create = try #require(result.first { $0.table == "new_orders" })
        #expect(create.sqlForReview?.hasPrefix("CREATE TABLE `target``db`.`new_orders`") == true)
        #expect(create.sqlForReview?.contains("AUTO_INCREMENT") == true)
        let modify = try #require(result.first { $0.object == "column:note" })
        #expect(modify.sqlForReview?.contains("MODIFY COLUMN `note` varchar ( 255 )") == true)
        #expect(modify.needsDestructiveReview)
        let drop = try #require(result.first { $0.table == "legacy" })
        #expect(drop.sqlForReview == "DROP TABLE `target``db`.`legacy`;")
        #expect(drop.needsDestructiveReview)
        #expect(create.planOrder < modify.planOrder && modify.planOrder < drop.planOrder)
    }
    @Test func indexAdditionRecordsItsColumnDependency() throws {
        let result = try SchemaComparisonEngine.compare(
            source: snapshot("source", [("orders", "`id` int, `note` varchar(20), KEY `idx_note` (`note`)")]),
            target: snapshot("target", [("orders", "`id` int")]))
        let column = try #require(result.first { $0.object == "column:note" })
        let index = try #require(result.first { $0.object == "index:idx_note" })
        #expect(index.sqlForReview != nil)
        #expect(index.requiredIDs == [column.id])
        #expect(column.planOrder < index.planOrder)
    }
    @Test func unsupportedGeneratedColumnDoesNotGainAnIndexPlan() throws {
        let result = try SchemaComparisonEngine.compare(
            source: snapshot("source", [("orders", "`id` int, `x` int GENERATED ALWAYS AS (`id` + 1) STORED, KEY `idx_x` (`x`)")]),
            target: snapshot("target", [("orders", "`id` int")]))
        #expect(result.allSatisfy { $0.sqlForReview == nil })
    }
    @Test func foreignKeyTableCreationIsNotSilentlyStripped() throws {
        let result = try SchemaComparisonEngine.compare(
            source: snapshot("source", [("child", "`id` int, CONSTRAINT `fk` FOREIGN KEY (`id`) REFERENCES `parent` (`id`)")]),
            target: snapshot("target", []))
        #expect(result.first?.sqlForReview == nil)
        #expect(result.first?.sourceDDL.contains("REFERENCES") == true)
    }
    @Test func failedMetadataBlocksTheEntireReviewPlan() throws {
        var source = try snapshot("source", [("new_orders", "`id` int")])
        source = .init(database: source.database, serverID: source.serverID, version: source.version, sqlMode: source.sqlMode,
                       lowerCaseTableNames: 0, objects: source.objects + [.init(name: "broken", ddl: "", definition: nil, error: "denied")], capturedAt: .now)
        let result = try SchemaComparisonEngine.compare(source: source, target: snapshot("target", [("legacy", "`id` int")]))
        #expect(result.allSatisfy { $0.sqlForReview == nil })
    }
}
