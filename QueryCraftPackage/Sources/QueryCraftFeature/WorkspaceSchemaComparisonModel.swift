import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceSchemaComparisonModel {
    struct Endpoint: Equatable {
        var profileID: UUID?
        var database = ""
        var password = ""
    }

    enum Phase { case idle, loading, ready, failed }
    var source = Endpoint() { didSet { if source != oldValue { invalidate() } } }
    var target = Endpoint() { didSet { if target != oldValue { invalidate() } } }
    var selectedIDs: Set<String> = [] { didSet { if selectedIDs != oldValue { regeneratePlan() } } }
    var focusedID: String? { didSet { if focusedID != oldValue { regenerateFocusedPlan() } } }
    var search = ""
    var showsEqual = false
    var statusFilter: SchemaComparisonDifference.Status?
    var options = SchemaComparisonOptions() { didSet { if options != oldValue { invalidate() } } }
    private(set) var nativeResult: SchemaComparisonNativeDocument?
    private(set) var nativePlan: SchemaComparisonNativePlan?
    private(set) var isPlanningFocus = false
    private(set) var focusedScript = ""
    @ObservationIgnored private var focusTask: Task<Void, Never>?
    @ObservationIgnored private var focusRevision = UUID()
    private(set) var isPreparingDeployment = false
    private var retainedScript = ""
    var displayScript: String { nativePlan?.sql ?? (phase == .ready ? script : retainedScript) }
    private(set) var isPlanning = false
    var ignoreForeignKeyChecks = false { didSet { if ignoreForeignKeyChecks != oldValue { regeneratePlan(); regenerateFocusedPlan() } } }
    private var plannedIDs: Set<String> = []
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored private var planRevision = UUID()
    @ObservationIgnored private let nativeEngine: SchemaComparisonNativeEngine
    private(set) var lastDeployedComparison: UUID?
    var hasDeployedCurrentComparison: Bool { comparedAt != nil && lastDeployedComparison == revision }
    var canRollback: Bool { hasDeployedCurrentComparison && deployment.phase == .succeeded && !deployment.isRollback && nativePlan?.rollbackComplete == true && nativePlan?.rollbackStatements.isEmpty == false }
    let deployment: SchemaComparisonDeployment
    @ObservationIgnored private let sessionFactory: any WorkspaceSessionFactory
    private(set) var sourceSnapshot: SchemaComparisonSnapshot?
    private(set) var targetSnapshot: SchemaComparisonSnapshot?
    private(set) var profiles: [ConnectionProfile] = []
    private(set) var isLoadingProfiles = false
    private(set) var phase: Phase = .idle
    private(set) var differences: [SchemaComparisonDifference] = []
    private(set) var errorMessage: String?
    private(set) var progress = ""
    private(set) var readingProgress = SchemaComparisonProgress()
    private(set) var isCancelling = false
    private(set) var comparedAt: Date?
    private(set) var sourceVersion = ""
    private(set) var targetVersion = ""

    @ObservationIgnored private let repository: any ConnectionProfileRepository
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let loader: any SchemaComparisonSnapshotLoading
    @ObservationIgnored private let databaseLoader: any SchemaComparisonDatabaseListing
    @ObservationIgnored private let tableLoader: any SchemaComparisonTableListing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()

    init(
        repository: any ConnectionProfileRepository = SQLiteConnectionProfileRepository(),
        credentials: any CredentialStore = KeychainCredentialStore(),
        sessionFactory: any WorkspaceSessionFactory = DefaultWorkspaceSessionFactory(),
        snapshotLoader: (any SchemaComparisonSnapshotLoading)? = nil,
        databaseLoader: (any SchemaComparisonDatabaseListing)? = nil,
        tableLoader: (any SchemaComparisonTableListing)? = nil,
        nativeEngine: SchemaComparisonNativeEngine = .init()
    ) {
        self.sessionFactory = sessionFactory
        self.deployment = SchemaComparisonDeployment(sessionFactory: sessionFactory)
        self.nativeEngine = nativeEngine
        self.repository = repository
        self.credentials = credentials
        loader = snapshotLoader ?? SchemaComparisonCatalogLoader(sessionFactory: sessionFactory)
        self.databaseLoader = databaseLoader ?? SchemaComparisonDatabaseLoader(sessionFactory: sessionFactory)
        self.tableLoader = tableLoader ?? SchemaComparisonTableLoader(sessionFactory: sessionFactory)
    }

    var canCompare: Bool {
        phase != .loading && !deployment.isBusy && !isPreparingDeployment && !isLoadingProfiles && source.profileID != nil && target.profileID != nil
            && !source.database.isEmpty && !target.database.isEmpty && options.hasScope && options.validationMessage == nil
    }

    var visibleDifferences: [SchemaComparisonDifference] {
        differences.filter {
            (showsEqual || $0.status != .equal)
                && (statusFilter == nil || $0.status == statusFilter)
                && (search.isEmpty || $0.table.localizedStandardContains(search)
                    || $0.object.localizedStandardContains(search))
        }
    }

    var focusedDifference: SchemaComparisonDifference? {
        focusedDifferences.first
    }

    var focusedDifferences: [SchemaComparisonDifference] {
        guard let focusedID else { return [] }
        if focusedID.hasPrefix("table:") || focusedID.hasPrefix("routine:") {
            return differences.filter { $0.groupKey == focusedID && (showsEqual || $0.status != .equal) }
        }
        return differences.filter { $0.id == focusedID }
    }

    var selectedDifferences: [SchemaComparisonDifference] {
        differences.filter { selectedIDs.contains($0.id) && $0.sqlForReview != nil }
            .sorted { $0.planOrder == $1.planOrder ? $0.id < $1.id : $0.planOrder < $1.planOrder }
    }

    var canExport: Bool {
        phase == .ready && !differences.contains(where: { $0.status == .unavailable }) && !isPlanning && !isPreparingDeployment && (nativeResult == nil || plannedIDs == selectedIDs) && !selectedDifferences.isEmpty
            && selectedDifferences.allSatisfy { $0.requiredIDs.isSubset(of: selectedIDs) }
    }

    var script: String {
        guard canExport else { return "" }
        if let nativePlan { return nativePlan.sql }
        // Server-provided names may contain newlines; keep the header inert.
        func line(_ value: String) -> String {
            value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        let header = """
        -- QueryCraft · MySQL schema comparison
        -- Source: \(line(endpointDescription(source))) / \(line(source.database)) · \(line(sourceVersion))
        -- Target: \(line(endpointDescription(target))) / \(line(target.database)) · \(line(targetVersion))
        -- Snapshot: \(comparedAt?.ISO8601Format() ?? "")
        -- Included tables: \(options.includedTables.isEmpty ? "all" : line(options.includedTables))
        -- Excluded tables: \(line(options.excludedTables))
        -- Ignore comment differences: \(options.ignoresComments)
        -- Review target metadata and DDL lock costs before running. MySQL DDL may implicitly commit.
        -- Only selected supported changes are included. Review destructive statements before running.
        """
        return header + "\n\n" + selectedDifferences.compactMap(\.sqlForReview).joined(separator: "\n\n") + "\n"
    }

    func endpointDescription(_ endpoint: Endpoint) -> String {
        guard let profile = profiles.first(where: { $0.id == endpoint.profileID }) else { return "—" }
        return "\(profile.name) · \(profile.host):\(profile.port)"
    }

    func makeEndpointDraft(_ value: Endpoint) -> SchemaComparisonEndpointDraft {
        SchemaComparisonEndpointDraft(value: value, profile: profiles.first { $0.id == value.profileID },
                                      credentials: credentials, loader: databaseLoader, tableLoader: tableLoader)
    }

    func selectProfile(_ id: UUID?, isSource: Bool) {
        let profile = profiles.first { $0.id == id }
        let endpoint = Endpoint(profileID: id, database: profile?.defaultDatabase ?? "")
        if isSource { source = endpoint } else { target = endpoint }
    }

    func loadProfiles() async {
        guard !isLoadingProfiles else { return }
        isLoadingProfiles = true
        defer { isLoadingProfiles = false }
        do {
            let loaded = try await repository.fetchAll()
            try Task.checkCancellation()
            let updated = loaded.filter { $0.databaseProduct == .mysql }
            if !profiles.isEmpty, [source.profileID, target.profileID].compactMap({ $0 }).contains(where: { id in
                profiles.first { $0.id == id } != updated.first { $0.id == id }
            }) { invalidate() }
            profiles = updated
            if phase != .failed { errorMessage = nil }
            if source.profileID == nil { selectProfile(profiles.first?.id, isSource: true) }
            if target.profileID == nil { selectProfile(profiles.dropFirst().first?.id ?? profiles.first?.id, isSource: false) }
        } catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
    }

    func compare() {
        guard canCompare else { return }
        let sourceInput = source
        let targetInput = target
        let comparisonOptions = options
        let currentRevision = UUID()
        revision = currentRevision
        retainedScript = script
        phase = .loading
        isCancelling = false
        errorMessage = nil
        progress = AppCopy.current.text("正在连接两端…", "Connecting to both endpoints…")
        readingProgress = .init()
        let snapshotLoader: any SchemaComparisonSnapshotLoading
        if var mysql = loader as? MySQLSchemaSnapshotLoader {
            mysql.options = comparisonOptions
            snapshotLoader = mysql
        } else if var catalog = loader as? SchemaComparisonCatalogLoader {
            catalog.options = comparisonOptions
            snapshotLoader = catalog
        } else { snapshotLoader = loader }
        let oldSelected = Dictionary(uniqueKeysWithValues: selectedDifferences.map { ($0.id, $0) })
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let sourceConfig = try await configuration(sourceInput)
                let targetConfig = try await configuration(targetInput)
                try Task.checkCancellation()
                async let sourceSnapshot = loadSnapshot(sourceConfig, loader: snapshotLoader, side: .source, revision: currentRevision)
                async let targetSnapshot = loadSnapshot(targetConfig, loader: snapshotLoader, side: .target, revision: currentRevision)
                let (s, t) = try await (sourceSnapshot, targetSnapshot)
                try Task.checkCancellation()
                guard revision == currentRevision else { return }
                readingProgress.isComparing = true
                progress = AppCopy.current.text("正在计算结构差异…", "Comparing schema definitions…")
                let native: SchemaComparisonNativeResult?
                let result: [SchemaComparisonDifference]
                if s.engineMetadata != nil || t.engineMetadata != nil {
                    let prepared = try await nativeEngine.analyze(source: s, target: t, options: comparisonOptions)
                    native = prepared
                    result = prepared.differences
                } else {
                    // Injected legacy snapshots are used by parser regression tests.
                    native = nil
                    result = try await Self.compareSnapshots(source: s, target: t, options: comparisonOptions)
                }
                try Task.checkCancellation()
                guard revision == currentRevision else { return }
                self.sourceSnapshot = s
                self.targetSnapshot = t
                nativeResult = native?.raw
                nativePlan = native?.plan
                differences = result
                // Retain only exactly unchanged selections after refreshing.
                selectedIDs = Set(result.filter { native != nil && comparedAt == nil ? $0.sqlForReview != nil : oldSelected[$0.id] == $0 }.map(\.id))
                plannedIDs = native == nil ? [] : Set(result.filter { $0.sqlForReview != nil }.map(\.id))
                if !result.contains(where: { $0.id == focusedID || $0.groupKey == focusedID }) {
                    focusedID = (result.first(where: { $0.status != .equal }) ?? result.first).map(\.groupKey)
                }
                sourceVersion = s.version
                targetVersion = t.version
                comparedAt = max(s.capturedAt, t.capturedAt)
                phase = .ready
                regenerateFocusedPlan()
                if native != nil && plannedIDs != selectedIDs { regeneratePlan() }
            } catch {
                guard revision == currentRevision else { return }
                phase = .failed
                errorMessage = error is CancellationError
                    ? AppCopy.current.text("比较已取消。已有结果已过期，请重新比较。", "Comparison canceled. Recompare before exporting previous results.")
                    : error.localizedDescription
            }
            if revision == currentRevision {
                progress = ""
                isCancelling = false
                task = nil
            }
        }
    }

    // Snapshot comparison can be CPU-heavy for thousands of tables. Keep it off
    // the main actor while preserving structured cancellation from this task.
    nonisolated private static func compareSnapshots(
        source: SchemaComparisonSnapshot, target: SchemaComparisonSnapshot, options: SchemaComparisonOptions
    ) async throws -> [SchemaComparisonDifference] {
        try SchemaComparisonEngine.compare(source: source, target: target, options: options)
    }

    func cancel() {
        guard phase == .loading else { return }
        isCancelling = true
        task?.cancel()
        progress = AppCopy.current.text("正在停止，等待当前元数据请求结束…", "Stopping after the current metadata request…")
    }

    func waitForComparison() async {
        await task?.value
    }

    func close() {
        deployment.stop()
        invalidate()
        source.password = ""
        target.password = ""
    }

    func selectAdditions() {
        guard phase == .ready else { return }
        selectedIDs.formUnion(visibleDifferences.filter { $0.sql != nil }.map(\.id))
    }

    func selectPlannedChanges() {
        guard phase == .ready else { return }
        selectChanges(Set(visibleDifferences.filter { $0.sqlForReview != nil }.map(\.id)), selected: true)
    }

    func selectChanges(_ ids: Set<String>, selected: Bool) {
        guard phase == .ready else { return }
        if selected {
            selectedIDs.formUnion(ids)
            var previous: Set<String>
            repeat {
                previous = selectedIDs
                for difference in selectedDifferences { selectedIDs.formUnion(difference.requiredIDs) }
            } while previous != selectedIDs
        } else {
            selectedIDs.subtract(ids)
            var previous: Set<String>
            repeat {
                previous = selectedIDs
                for difference in selectedDifferences where !difference.requiredIDs.isSubset(of: selectedIDs) {
                    selectedIDs.remove(difference.id)
                }
            } while previous != selectedIDs
        }
    }

    private func loadSnapshot(_ configuration: DatabaseConnectionConfiguration, loader: any SchemaComparisonSnapshotLoading,
                              side: SchemaComparisonProgress.Side, revision: UUID) async throws -> SchemaComparisonSnapshot {
        let snapshot = try await loader.load(configuration: configuration) { [weak self] value in
            await self?.updateProgress(value, side: side, revision: revision)
        }
        updateProgress(.init(completed: snapshot.objects.count, total: snapshot.objects.count), side: side, revision: revision)
        return snapshot
    }

    private func updateProgress(_ value: SchemaComparisonLoadProgress, side: SchemaComparisonProgress.Side, revision: UUID) {
        guard self.revision == revision, !isCancelling else { return }
        readingProgress.accept(value, side: side)
        let s = readingProgress.source
        let t = readingProgress.target
        progress = AppCopy.current.text("源 \(s.completed)/\(s.total.map(String.init) ?? "—") · 目标 \(t.completed)/\(t.total.map(String.init) ?? "—")",
                                        "Source \(s.completed)/\(s.total.map(String.init) ?? "—") · Target \(t.completed)/\(t.total.map(String.init) ?? "—")")
    }

    func deploy(rollback: Bool = false) async throws {
        guard canExport, let plan = nativePlan, let sourceSnapshot, let targetSnapshot,
              !deployment.isBusy else { throw SchemaEngineFailure(AppCopy.current.text("请先重新比较并审核 SQL。", "Compare and review SQL first.")) }
        if rollback && (!plan.rollbackComplete || plan.rollbackStatements.isEmpty || deployment.phase != .succeeded || deployment.isRollback) {
            throw SchemaEngineFailure(AppCopy.current.text("当前没有可执行的完整回退计划。", "A complete executable rollback plan is not available."))
        }
        let confirmedSource = source, confirmedTarget = target, confirmedOptions = options
        let confirmedSelection = selectedDifferences, confirmedIDs = selectedIDs, confirmedRevision = revision
        isPreparingDeployment = true
        defer { isPreparingDeployment = false }
        let sourceConfig = try await configuration(confirmedSource), targetConfig = try await configuration(confirmedTarget)
        guard revision == confirmedRevision, selectedIDs == confirmedIDs, nativePlan?.sql == plan.sql, nativePlan?.rollbackSQL == plan.rollbackSQL else {
            throw SchemaEngineFailure(AppCopy.current.text("审核计划已改变，请重新审核后再执行。", "The reviewed plan changed. Review it again before execution."))
        }
        lastDeployedComparison = confirmedRevision
        deployment.start(statements: rollback ? plan.rollbackStatements : plan.statements,
            sourceConfiguration: sourceConfig, targetConfiguration: targetConfig, originalSource: sourceSnapshot,
            originalTarget: targetSnapshot, options: confirmedOptions, rollback: rollback, selection: confirmedSelection)
    }

    func waitForPlan() async { await planTask?.value }

    private func regenerateFocusedPlan() {
        focusTask?.cancel()
        focusRevision = UUID()
        let revision = focusRevision
        focusedScript = ""
        guard phase == .ready else { isPlanningFocus = false; return }
        guard let nativeResult else {
            focusedScript = focusedDifferences.compactMap(\.sqlForReview).joined(separator: "\n\n")
            isPlanningFocus = false
            return
        }
        var ids = Set(focusedDifferences.filter { $0.sqlForReview != nil }.map(\.id))
        var previous: Set<String>
        repeat {
            previous = ids
            for unit in nativeResult.units where ids.contains(unit.difference.id) { ids.formUnion(unit.difference.requiredIDs) }
        } while ids != previous
        let selection = ids, ignore = ignoreForeignKeyChecks
        isPlanningFocus = true
        focusTask = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await nativeEngine.plan(result: nativeResult, selectedIDs: selection, ignoreForeignKeyChecks: ignore)
                try Task.checkCancellation()
                guard focusRevision == revision else { return }
                focusedScript = plan.sql
            } catch { guard focusRevision == revision else { return }; focusedScript = error.localizedDescription }
            if focusRevision == revision { isPlanningFocus = false; focusTask = nil }
        }
    }

    private func regeneratePlan() {
        guard phase == .ready, let nativeResult else { return }
        planTask?.cancel()
        let revision = UUID()
        planRevision = revision
        let ids = selectedIDs
        let ignore = ignoreForeignKeyChecks
        isPlanning = true
        planTask = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await nativeEngine.plan(result: nativeResult, selectedIDs: ids, ignoreForeignKeyChecks: ignore)
                try Task.checkCancellation()
                guard planRevision == revision else { return }
                nativePlan = plan
                plannedIDs = ids
                errorMessage = nil
            } catch {
                guard planRevision == revision else { return }
                errorMessage = error.localizedDescription
                plannedIDs = []
            }
            if planRevision == revision { isPlanning = false; planTask = nil }
        }
    }

    private func invalidate() {
        focusTask?.cancel()
        focusRevision = UUID()
        isPlanningFocus = false
        focusedScript = ""
        retainedScript = ""
        planTask?.cancel()
        planRevision = UUID()
        isPlanning = false
        nativeResult = nil
        nativePlan = nil
        sourceSnapshot = nil
        targetSnapshot = nil
        plannedIDs = []
        task?.cancel()
        revision = UUID()
        phase = .idle
        isCancelling = false
        progress = ""
        readingProgress = .init()
        differences = []
        selectedIDs = []
        focusedID = nil
        errorMessage = nil
        comparedAt = nil
        sourceVersion = ""
        targetVersion = ""
    }

    private func configuration(_ endpoint: Endpoint) async throws -> DatabaseConnectionConfiguration {
        guard let profile = profiles.first(where: { $0.id == endpoint.profileID }) else {
            throw WorkspaceError.profileNotFound
        }
        let password: String?
        if !endpoint.password.isEmpty { password = endpoint.password }
        else if profile.storesCredential { password = try await credentials.password(for: profile.id) }
        else { password = nil }
        try Task.checkCancellation()
        return DatabaseConnectionConfiguration(databaseProduct: .mysql, host: profile.host, port: profile.port,
                                               authentication: profile.authentication(secret: password),
                                               database: endpoint.database, tlsMode: profile.tlsMode)
    }
}
