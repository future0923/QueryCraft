import Foundation
import Observation
import UIKit
import QueryCraftMobileCore

struct MobileImportPreviewRow: Identifiable { let id: String; let number: Int; let cells: [String?] }

@MainActor @Observable final class MobileDataImportModel: Identifiable {
    let id = UUID()
    let object: MobileDatabaseObject
    let configuration: MobileSQLConfiguration
    let safetyLock: WorkspaceSafetyLock
    var options = WorkspaceDataImportOptions() { didSet { revision = UUID(); prepared = nil } }
    var mapping: [String?] = [] { didSet { revision = UUID(); prepared = nil } }
    var batchSize = 500 { didSet { revision = UUID(); prepared = nil } }
    private(set) var fileURL: URL?
    private(set) var file: WorkspaceDataImportFile?
    private var fileIdentity = UUID()
    var previewRows: [MobileImportPreviewRow] { (file?.previewRows.prefix(max(0, options.previewRows)) ?? []).enumerated().map { .init(id: fileIdentity.uuidString + ":" + String($0.offset), number: $0.offset + 1, cells: $0.element) } }
    private var loadedOptions: WorkspaceDataImportOptions?
    private(set) var schema: WorkspaceDataImportSchema?
    private(set) var isLoading = false
    private(set) var isRunning = false
    private(set) var isCancelling = false
    private(set) var completedRows = 0
    private(set) var outcome: WorkspaceDataImportOutcome?
    private(set) var prepared: WorkspaceDataImportPlan?
    private(set) var exampleSQL: String?
    var message: String?
    var showing = true
    var isBackgrounded = false
    private var revision = UUID()
    private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    private let service: any MobileDataImportServicing
    @ObservationIgnored var contextIsCurrent: () -> Bool = { false }
    @ObservationIgnored var allowsWrites: () -> Bool = { false }
    @ObservationIgnored var didComplete: () -> Void = {}
    init(object: MobileDatabaseObject, configuration: MobileSQLConfiguration, safetyLock: WorkspaceSafetyLock,
         service: any MobileDataImportServicing = MobilePostgreSQLImportService()) {
        self.object = object; self.configuration = configuration; self.safetyLock = safetyLock; self.service = service
        options.sqlBackslashEscapes = false
    }
    var needsVerification: Bool { outcome?.status == .uncertain }
    var blocksWrites: Bool { isRunning || needsVerification }
    var hasPendingChanges: Bool { blocksWrites || (fileURL != nil && outcome?.status != .completed) }
    var canEdit: Bool { outcome?.status != .completed && !isLoading && !isRunning && !needsVerification && !isBackgrounded && contextIsCurrent() }
    var hasCurrentPreview: Bool { file != nil && loadedOptions == options }
    var plan: WorkspaceDataImportPlan? {
        guard let file, let schema else { return nil }
        return .init(file: file, schema: schema, mapping: mapping, batchSize: batchSize, dialect: .postgresql)
    }
    func select(_ url: URL) {
        guard canEdit else { return }; cancelRead(); fileURL = url; file = nil; schema = nil; mapping = []; outcome = nil; message = nil; exampleSQL = nil
        setFormat(.detect(url))
    }
    func setFormat(_ format: WorkspaceDataImportFormat) {
        guard canEdit else { return }
        options.format = format; options.delimiter = format == .tsv ? "\t" : ","
        options.headerRow = format == .json ? 0 : 1; options.firstDataRow = format == .json ? 1 : 2; options.sheetIndex = 0
    }
    @discardableResult func load() -> Task<Void, Never>? {
        guard canEdit, let url = fileURL else { return nil }
        cancelRead(); let id = UUID(); generation = id; let options = options
        isLoading = true; message = nil; prepared = nil; loadedOptions = nil
        let pending = Task { [weak self, service, object, configuration] in
            do {
                async let data = WorkspaceDataImportReader().read(url: url, options: options)
                async let columns = service.schema(object: object, configuration: configuration)
                let (file, schema) = try await (data, columns); try Task.checkCancellation()
                guard let self, self.generation == id else { return }
                self.isLoading = false; self.task = nil
                guard self.contextIsCurrent(), !self.isBackgrounded else { return }
                self.loadedOptions = options; self.fileIdentity = UUID(); self.file = file; self.schema = schema; self.mapping = schema.automaticMapping(file.columns); self.outcome = nil
            } catch {
                guard let self, self.generation == id else { return }
                self.isLoading = false; self.task = nil
                if !(error is CancellationError) { self.message = error.localizedDescription }
            }
        }
        task = pending; return pending
    }
    @discardableResult func prepare() -> Task<Void, Never>? {
        guard canEdit, loadedOptions == options, let plan else { return nil }
        let captured = revision, id = UUID(); generation = id; isLoading = true; message = nil
        let pending = Task { [weak self] in
            do {
                let example = try await MobileImportPreviewWorker().validate(plan)
                try Task.checkCancellation(); guard let self, self.generation == id else { return }
                self.isLoading = false; self.task = nil
                guard self.revision == captured, self.contextIsCurrent(), !self.isBackgrounded else { return }
                self.prepared = plan; self.exampleSQL = example
            } catch {
                guard let self, self.generation == id else { return }
                self.isLoading = false; self.task = nil
                if !(error is CancellationError) { self.message = error.localizedDescription }
            }
        }; task = pending; return pending
    }
    private func authorize() throws {
        guard contextIsCurrent(), allowsWrites(), !isBackgrounded else { throw MobileSchemaError.stale }
        guard !safetyLock.isEnabled else { throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled }
    }
    @discardableResult func run() -> Task<Void, Never>? {
        guard canEdit, let plan = prepared else { return nil }
        do { try authorize() } catch { message = error.localizedDescription; return nil }
        isRunning = true; isCancelling = false; completedRows = 0; outcome = nil; message = nil
        let captured = revision
        let lifetime = UIApplication.shared.beginBackgroundTask(withName: "Finish PostgreSQL import") { [weak self] in Task { @MainActor [weak self] in self?.cancel() } }
        let pending = Task { [self, service, object, configuration] in
            defer { isRunning = false; isCancelling = false; task = nil; if lifetime != .invalid { UIApplication.shared.endBackgroundTask(lifetime) } }
            let result = await service.run(object: object, configuration: configuration, plan: plan, authorize: { [weak self] in
                guard let self, self.revision == captured else { throw MobileSchemaError.stale }; try self.authorize()
            }, progress: { [weak self] count in await self?.receive(count) })
            outcome = result; prepared = nil
            if result.status == .completed || result.status == .uncertain { didComplete() }
            if result.status == .uncertain { safetyLock.enable() }
        }; task = pending; return pending
    }
    private func receive(_ rows: Int) { completedRows = rows }
    func cancelRead() { if !isRunning { generation = UUID(); task?.cancel(); task = nil; isLoading = false } }
    func cancel() { if isRunning { isCancelling = true; task?.cancel() } else { cancelRead() } }
    func background(_ value: Bool) { isBackgrounded = value; if value { safetyLock.enable(); cancel() } }
}
private actor MobileImportPreviewWorker {
    func validate(_ plan: WorkspaceDataImportPlan) throws -> String {
        try plan.validate()
        let file = try WorkspaceDataImportFile(columns: plan.file.columns, rows: plan.file.readRows(in: 0..<min(1, plan.file.rowCount)))
        return String(try WorkspaceDataImportPlan(file: file, schema: plan.schema, mapping: plan.mapping, batchSize: 1, dialect: plan.dialect).statement(from: 0).sql.prefix(4000))
    }
}
