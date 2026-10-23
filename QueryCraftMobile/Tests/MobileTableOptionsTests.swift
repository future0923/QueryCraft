import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor struct MobileTableOptionsTests {
    static let baseline = WorkspaceDatabaseTableOptions(engine: "InnoDB", characterSet: "utf8mb4", collation: "utf8mb4_bin", rowFormat: "DYNAMIC", autoIncrement: "50", comment: "original", averageRowLength: "128", minimumRows: "1", maximumRows: "100", keyBlockSize: "0")
    func fixture() async throws -> (MobileSchemaController,MobileSchemaDraft,SchemaStateService) {
        let s = SchemaStateService(); await s.setOptions(Self.baseline)
        let (c,o) = MobileSchemaStateTests().fixture(service: s); await c.load(o)?.value
        return (c,c.draft(for: o),s)
    }
    @Test func optionsColumnsAndIndexesShareOneOrderedPlanAndDiscardRestoresEveryValue() async throws {
        let (c,d,_) = try await fixture(); let baseline = d.state.tableOptions
        #expect(!d.hasChanges); #expect(d.plan.statements.isEmpty)
        var options = baseline; options.comment = "new'comment"; options.autoIncrement = "90"; d.updateOptions(options)
        try MobileSchemaStateTests().stage(d)
        #expect(d.hasChanges); #expect(d.plan.statements.count == 2)
        #expect(d.plan.statements.last?.sql.contains("COMMENT='new''comment'") == true)
        #expect(d.plan.statements.last?.sql.contains("AUTO_INCREMENT=90") == true)
        #expect(d.plan.statements.last?.sql.contains("ENGINE=") == false)
        d.section = .indexes; d.presentation = .list; #expect(d.state.tableOptions == options)
        #expect(c.load(d.object) == nil); #expect(d.state.tableOptions == options)
        d.discard(); #expect(!d.hasChanges); #expect(d.state.tableOptions == baseline)
    }
    @Test(arguments: 0..<10)
    func optimisticComparisonChecksExplicitChangedFieldsOnly(_ fieldIndex: Int) {
        let fields: [WritableKeyPath<WorkspaceDatabaseTableOptions,String>] = [\.engine, \.characterSet, \.collation, \.rowFormat, \.autoIncrement, \.comment, \.averageRowLength, \.minimumRows, \.maximumRows, \.keyBlockSize]
        let field = fields[fieldIndex]
        let original = Self.baseline; var updated = original; updated[keyPath: field] = "edited"
        let change = WorkspaceDatabaseTableOptionsChange(original: original, updated: updated)
        var concurrent = original; concurrent[keyPath: field] = "external"
        #expect(!change.matchesOriginalChangedValues(in: concurrent))
        #expect(change.matchesOriginalChangedValues(in: original))
    }
    @Test func unrelatedDynamicAutoIncrementDoesNotBecomePartOfCommentPlan() {
        let original = Self.baseline; var updated = original; updated.comment = "changed"
        let change = WorkspaceDatabaseTableOptionsChange(original: original, updated: updated)
        var current = original; current.autoIncrement = "51"
        #expect(change.matchesOriginalChangedValues(in: current))
    }
    @Test func missingOrViewMetadataCannotStageFakeDefaultsAndStalePreviewNeverSubmits() async throws {
        let (c,o) = MobileSchemaStateTests().fixture(); await c.load(o)?.value
        let missing = c.draft(for: o); missing.updateOptions(Self.baseline); #expect(!missing.hasChanges)
        let (controller,draft,service) = try await fixture(); var options = draft.state.tableOptions; options.comment = "first"; draft.updateOptions(options)
        let captured = draft.plan; options.comment = "second"; draft.updateOptions(options)
        controller.safetyLock.disable(); #expect(controller.submit(draft, expectedPlan: captured) == nil); #expect(await service.applies == 0)
        let view = MobileDatabaseObject(database: "db", name: "v", kind: .view, comment: "")
        await c.load(view)?.value; #expect(!c.canEdit(c.draft(for: view)))
    }
    @Test func readFailureAndLateCancelledReplyKeepOptionsAndCleanLoadingState() async throws {
        let (c,d,s) = try await fixture(); let epoch = d.epoch
        await s.setReadFailure(true); await c.load(d.object)?.value
        #expect(d.state.tableOptions == Self.baseline); #expect(d.epoch == epoch); #expect(d.isError)
        await s.setReadFailure(false); await s.setGate(true)
        let task = c.load(d.object); await s.waitForGate(); c.contextID = { UUID() }
        await s.setOptions(.init(comment: "late")); await s.releaseGate(); await task?.value
        #expect(!c.isLoading); #expect(d.state.tableOptions == Self.baseline); #expect(d.epoch == epoch)
    }
    @Test func confirmedOptionsWithFailedReadRemainFencedUntilSuccessfulPublicReload() async throws {
        let (c,d,s) = try await fixture(); var options = d.state.tableOptions; options.comment = "changed"; d.updateOptions(options)
        c.safetyLock.disable(); await s.setFailAfterApply(true); await c.submit(d)?.value
        #expect(d.requiresReload); #expect(!d.needsVerification); #expect(c.submit(d) == nil)
        #expect(await s.writes == 1); await s.setReadFailure(false); await c.load(d.object)?.value
        #expect(!d.hasChanges); #expect(d.state.tableOptions.comment == "changed"); #expect(!d.requiresReload)
    }
    @Test func changedDefinitionDuringAuthorizationCannotExecuteUnpreviewedOptions() async throws {
        let (c,d,s) = try await fixture(); var options = d.state.tableOptions; options.comment = "first"; d.updateOptions(options)
        await s.setWriteGate(true); c.safetyLock.disable(); let task = c.submit(d)
        await s.waitForGate(); options.comment = "late edit"; d.updateOptions(options)
        await s.releaseGate(); await task?.value
        #expect(await s.writes == 0); #expect(d.hasChanges); #expect(!d.needsVerification)
    }
    @Test func optionsMetadataConversionPreservesUnknownValuesAndParsesAdvancedHints() {
        let info = MySQLTableSchemaMetadata.information(["table_engine":"MyISAM", "table_collation":"utf8mb4_bin", "row_format":"Dynamic", "next_auto_increment":"9007199254740993", "table_comment":"真实注释", "create_options":"min_rows=3 MAX_ROWS=999 avg_row_length=256 key_block_size=8"])
        #expect(info.tableOptions.engine == "MyISAM"); #expect(info.tableOptions.rowFormat == "DYNAMIC")
        #expect(info.tableOptions.characterSet == "utf8mb4"); #expect(info.tableOptions.autoIncrement == "9007199254740993")
        #expect(info.tableOptions.minimumRows == "3"); #expect(info.tableOptions.maximumRows == "999")
        #expect(info.tableOptions.averageRowLength == "256"); #expect(info.tableOptions.keyBlockSize == "8")
        #expect(MySQLTableSchemaMetadata.information([:]).tableOptions == .init())
        let sql = MySQLTableSchemaMetadata.informationQuery(database: "库'名", name: "表`名")
        #expect(!sql.contains("库'名")); #expect(!sql.contains("表`名")); #expect(sql.contains("information_schema.TABLES"))
    }
}
