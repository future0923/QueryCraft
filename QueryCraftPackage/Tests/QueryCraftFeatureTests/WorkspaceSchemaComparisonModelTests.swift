import Foundation
import Testing
@testable import QueryCraftFeature

private actor ComparisonFixtureLoader: SchemaComparisonSnapshotLoading {
    var fails = false
    var changed = false
    var includesIndex = false
    let started = CatalogPhaseGate()
    private var gate: CatalogPhaseGate?

    func fail() { fails = true }
    func changeDefinition() { changed = true }
    func includeIndex() { includesIndex = true }
    func suspend(on gate: CatalogPhaseGate) { self.gate = gate }

    func load(configuration: DatabaseConnectionConfiguration,
              progress: @escaping @Sendable (SchemaComparisonLoadProgress) async -> Void) async throws -> SchemaComparisonSnapshot {
        await started.open()
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        if fails { throw SchemaComparisonError.invalidDatabase }
        let source = configuration.database == "dev"
        let ddl = source
            ? "CREATE TABLE `orders` (`id` int, `note` varchar(\(changed ? 128 : 255)) DEFAULT NULL\(includesIndex ? ", KEY `idx_note` (`note`)" : ""))"
            : "CREATE TABLE `orders` (`id` int)"
        return .init(database: configuration.database ?? "", serverID: "server", version: "8.0.40",
                     sqlMode: "", lowerCaseTableNames: 0,
                     objects: [.init(name: "orders", ddl: ddl, definition: try MySQLSchemaDefinition(ddl: ddl), error: nil)],
                     capturedAt: Date(timeIntervalSince1970: 0))
    }
}

private actor ComparisonProgressFixtureLoader: SchemaComparisonSnapshotLoading {
    let bothStarted = CatalogPhaseGate()
    let finish = CatalogPhaseGate()
    private var reporters: [String: @Sendable (SchemaComparisonLoadProgress) async -> Void] = [:]
    func emit(_ database: String, _ event: SchemaComparisonLoadProgress) async { await reporters[database]?(event) }
    func load(configuration: DatabaseConnectionConfiguration,
              progress: @escaping @Sendable (SchemaComparisonLoadProgress) async -> Void) async throws -> SchemaComparisonSnapshot {
        let database = configuration.database ?? ""
        reporters[database] = progress
        if reporters.count == 2 { await bothStarted.open() }
        await finish.wait()
        try Task.checkCancellation()
        let count = database == "dev" ? 3 : 2
        let objects = try (0..<count).map { i in
            let ddl = "CREATE TABLE `t\(i)` (`id` int)"
            return SchemaComparisonSnapshot.Object(name: "t\(i)", ddl: ddl, definition: try .init(ddl: ddl), error: nil)
        }
        return .init(database: database, serverID: "server", version: "8.0.46", sqlMode: "", lowerCaseTableNames: 0,
                     objects: objects, capturedAt: .now)
    }
}

@MainActor
struct WorkspaceSchemaComparisonModelTests {
    private func profile(_ name: String, product: DatabaseProduct = .mysql) -> ConnectionProfile {
        .init(id: UUID(), name: name, groupID: nil, databaseProduct: product,
              host: "localhost", port: 3306, username: "root", defaultDatabase: name,
              tlsMode: .disabled, storesCredential: false, createdAt: .now)
    }

    private func model(_ loader: ComparisonFixtureLoader) async -> WorkspaceSchemaComparisonModel {
        let model = WorkspaceSchemaComparisonModel(
            repository: InMemoryConnectionProfileRepository(profiles: [profile("dev"), profile("test")]),
            credentials: InMemoryCredentialStore(), snapshotLoader: loader
        )
        await model.loadProfiles()
        return model
    }

    @Test func nonMySQLConnectionsAreExcluded() async {
        let profiles = DatabaseProduct.allCases.map { profile($0.rawValue, product: $0) }
        let model = WorkspaceSchemaComparisonModel(repository: InMemoryConnectionProfileRepository(profiles: profiles))
        await model.loadProfiles()
        #expect(model.profiles.count == 1)
        #expect(model.profiles.first?.databaseProduct == .mysql)
    }

    @Test func selectionsStartEmptyAndRefreshFailureKeepsStaleResultsWithoutExport() async throws {
        let loader = ComparisonFixtureLoader()
        let model = await model(loader)
        model.compare()
        await model.waitForComparison()
        #expect(model.phase == .ready)
        #expect(model.selectedIDs.isEmpty)
        model.selectAdditions()
        #expect(model.canExport)
        #expect(model.script.contains("`test`.`orders`"))
        #expect(model.script.contains("DROP") == false)
        let old = model.differences
        await loader.fail()
        model.compare()
        #expect(model.differences == old)
        #expect(model.canExport == false)
        await model.waitForComparison()
        #expect(model.phase == .failed)
        #expect(model.differences == old)
        #expect(model.script.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test func onlyUnchangedSelectionsSurviveRefresh() async {
        let loader = ComparisonFixtureLoader()
        let model = await model(loader)
        model.compare()
        await model.waitForComparison()
        model.selectAdditions()
        let selection = model.selectedIDs
        model.compare()
        await model.waitForComparison()
        #expect(model.selectedIDs == selection)
        await loader.changeDefinition()
        model.compare()
        await model.waitForComparison()
        #expect(model.selectedIDs.isEmpty)
        #expect(model.differences.contains { $0.source.contains("128") })
    }

    @Test func changedEndpointRejectsLateResults() async {
        let loader = ComparisonFixtureLoader()
        let gate = CatalogPhaseGate()
        await loader.suspend(on: gate)
        let model = await model(loader)
        model.compare()
        await loader.started.wait()
        model.source.database = "another_database"
        await gate.open()
        await model.waitForComparison()
        #expect(model.phase == .idle)
        #expect(model.differences.isEmpty)
        #expect(model.canExport == false)
    }

    @Test func cancelWaitsForRequestCleanupAndNeverPublishesItsResults() async {
        let loader = ComparisonFixtureLoader()
        let gate = CatalogPhaseGate()
        await loader.suspend(on: gate)
        let model = await model(loader)
        model.compare()
        await loader.started.wait()
        model.cancel()
        #expect(model.phase == .loading)
        #expect(model.isCancelling)
        #expect(model.canCompare == false)
        await gate.open()
        await model.waitForComparison()
        #expect(model.phase == .failed)
        #expect(model.differences.isEmpty)
        #expect(model.isCancelling == false)
    }

    @Test func duplicateRefreshDoesNotStartAnotherGeneration() async {
        let loader = ComparisonFixtureLoader()
        let gate = CatalogPhaseGate()
        await loader.suspend(on: gate)
        let model = await model(loader)
        model.compare()
        await loader.started.wait()
        model.compare()
        await gate.open()
        await model.waitForComparison()
        #expect(model.phase == .ready)
        #expect(model.differences.count == 2)
    }
    @Test func closingReadyWindowInvalidatesExportEvenWithoutEnteredPasswords() async {
        let model = await model(ComparisonFixtureLoader())
        model.compare()
        await model.waitForComparison()
        model.selectAdditions()
        #expect(model.canExport)
        model.close()
        #expect(model.phase == .idle)
        #expect(model.script.isEmpty)
        #expect(model.differences.isEmpty)
    }

    @Test func endpointChangeResetsCancellationAndProgress() async {
        let loader = ComparisonFixtureLoader()
        let gate = CatalogPhaseGate()
        await loader.suspend(on: gate)
        let model = await model(loader)
        model.compare()
        await loader.started.wait()
        model.cancel()
        #expect(model.isCancelling)
        model.target.database = "new_target"
        #expect(model.phase == .idle)
        #expect(model.isCancelling == false)
        #expect(model.progress.isEmpty)
        await gate.open()
        await model.waitForComparison()
        #expect(model.differences.isEmpty)
    }

    @Test func closeDuringLoadClearsSecretsAndRejectsLateResults() async {
        let loader = ComparisonFixtureLoader()
        let gate = CatalogPhaseGate()
        await loader.suspend(on: gate)
        let model = await model(loader)
        model.source.password = "temporary-source-secret"
        model.target.password = "temporary-target-secret"
        model.compare()
        await loader.started.wait()
        model.close()
        #expect(model.source.password.isEmpty && model.target.password.isEmpty)
        #expect(model.phase == .idle)
        #expect(model.progress.isEmpty)
        await gate.open()
        await model.waitForComparison()
        #expect(model.differences.isEmpty && model.script.isEmpty)
    }

    @Test func concurrentProgressCountsCompletedObjectsAndCancellationRejectsLateEvents() async {
        let loader = ComparisonProgressFixtureLoader()
        let model = WorkspaceSchemaComparisonModel(repository: InMemoryConnectionProfileRepository(profiles: [profile("dev"), profile("test")]),
            credentials: InMemoryCredentialStore(), snapshotLoader: loader)
        await model.loadProfiles()
        model.compare(); await loader.bothStarted.wait()
        await loader.emit("dev", .init(completed: 1, total: 3, objectName: "first"))
        #expect(model.readingProgress.fraction == nil)
        await loader.emit("test", .init(completed: 1, total: 2, objectName: "other"))
        #expect(model.readingProgress.fraction == 0.4)
        #expect(model.readingProgress.source.objectName == "first")
        #expect(model.readingProgress.target.objectName == "other")
        model.cancel()
        let progress = model.readingProgress
        await loader.emit("test", .init(completed: 2, total: 2))
        #expect(model.readingProgress == progress)
        await loader.finish.open(); await model.waitForComparison()
        #expect(model.phase == .failed)
        #expect(model.differences.isEmpty)
        model.close()
        await loader.emit("dev", .init(completed: 3, total: 3))
        #expect(model.readingProgress == .init())
    }

    @Test func selectingAnIndexIncludesItsRequiredColumnAndDeselectingColumnRemovesIndex() async throws {
        let loader = ComparisonFixtureLoader()
        await loader.includeIndex()
        let model = await model(loader)
        model.compare(); await model.waitForComparison()
        let index = try #require(model.differences.first { $0.object == "index:idx_note" })
        let column = try #require(model.differences.first { $0.object == "column:note" })
        model.selectChanges([index.id], selected: true)
        #expect(model.selectedIDs == [index.id, column.id])
        #expect(model.canExport)
        #expect(model.selectedDifferences.map(\.id) == [column.id, index.id])
        model.selectChanges([column.id], selected: false)
        #expect(model.selectedIDs.isEmpty)
        #expect(!model.canExport)
    }

}
