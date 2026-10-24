import Foundation
import Observation
import QueryCraftMobileCore

struct MobileElasticsearchPlan: Sendable {
    let requests: [WorkspaceRequest]
    var preflight: @Sendable (any MobileElasticsearchServing) async throws -> Void = { _ in }
    let send: @Sendable (any MobileElasticsearchServing) async throws -> String
    let verification: @Sendable (any MobileElasticsearchServing) async throws -> String
}

struct MobileElasticsearchBatchFailure: LocalizedError, Sendable {
    let acknowledged: [String]
    let failure: String
    var errorDescription: String? { "部分操作已确认成功，后续操作已停止：" + failure }
}

enum MobileElasticsearchFailure: LocalizedError {
    case unavailable, stale, uncertain, rejected(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "当前操作不可用。"
        case .stale: "内容或上下文已改变，请重新预览。"
        case .uncertain: "请求可能已经执行，禁止直接重试。请只读核实服务器状态后明确结束本次操作。"
        case .rejected(let message): message
        }
    }
    static func acknowledged(_ response: WorkspaceRequestExecutionResult) throws -> String {
        try accepted(response)
        guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any], root["acknowledged"] as? Bool == true else { throw Self.uncertain }
        return String(decoding: response.body, as: UTF8.self)
    }
    static func accepted(_ response: WorkspaceRequestExecutionResult) throws {
        if response.statusCode == 408 || response.statusCode >= 500 { throw Self.uncertain }
        guard (200..<300).contains(response.statusCode) else { throw Self.rejected("HTTP \(response.statusCode)\n" + String(decoding: response.body, as: UTF8.self)) }
    }
    static func isDefinite(_ error: Error) -> Bool {
        if case Self.rejected = error { return true }
        if error is WorkspaceDocumentEditingError { return true }
        if case ElasticsearchError.server(let status, _) = error { return status != 408 && status < 500 }
        if case ElasticsearchError.forbidden = error { return true }
        if case ElasticsearchError.unauthorized = error { return true }
        return false
    }
}

@MainActor @Observable final class MobileElasticsearchAction: Identifiable {
    enum Kind: String, CaseIterable { case document, cellChanges, batchDelete, createDocument, pasteDocuments, mapping, settings, aliases, createIndex, deleteIndex, templates, simulate
        var title: String { switch self {
        case .document: "文档详情与编辑"; case .cellChanges: "待提交字段修改"; case .batchDelete: "批量删除文档"; case .createDocument: "新建文档"; case .pasteDocuments: "粘贴文档"; case .mapping: "编辑 Mapping"; case .settings: "索引设置"; case .aliases: "Alias 绑定"; case .createIndex: "新建索引"; case .deleteIndex: "删除索引"; case .templates: "索引模板"; case .simulate: "模拟索引模板"
        } }
    }
    let id = UUID()
    let kind: Kind
    let object: WorkspaceDatabaseObject?
    let reference: WorkspaceDocumentReference?
    unowned let owner: MobileElasticsearchWorkspace
    var name = "" { didSet { invalidate() } }
    var documentID = "" { didSet { invalidate() } }
    var routing = "" { didSet { invalidate() } }
    var source = "{}" { didSet { invalidate() } }
    var secondary = "" { didSet { invalidate() } }
    var replicas = "" { didSet { invalidate() } }
    var shards = "" { didSet { invalidate() } }
    var selectedRows: Set<Int> = [] { didSet { invalidate() } }
    var templateSearch = ""
    var visibleTemplates: [WorkspaceElasticsearchIndexTemplateSnapshot] {
        guard !templateSearch.isEmpty else { return templates ?? [] }
        return (templates ?? []).filter { $0.matchesSearch(templateSearch) }
    }
    var fieldName = ""
    var fieldText = ""
    var fieldNull = false
    var mode = "replace" { didSet { invalidate() } }
    var mappingPath = "[\"properties\",\"new_field\"]" { didSet { invalidate() } }
    var mappingIsNew = true { didSet { invalidate() } }
    var aliasRows: [WorkspaceElasticsearchAliasEditorRow] = [] { didSet { invalidate() } }
    private(set) var document: WorkspaceDocumentSnapshot?
    private(set) var mapping: WorkspaceMappingSnapshot?
    private(set) var settings: WorkspaceIndexSettingsSnapshot?
    private(set) var aliases: WorkspaceElasticsearchAliasSnapshot?
    private(set) var templates: [WorkspaceElasticsearchIndexTemplateSnapshot]?
    private(set) var templateBaseline: WorkspaceElasticsearchIndexTemplateSnapshot?
    private(set) var raw = ""
    private(set) var preview: String?
    private(set) var message: String?
    private(set) var isLoading = false
    private(set) var isPreparing = false
    private(set) var isSubmitting = false
    private(set) var isVerifying = false
    private(set) var needsVerification = false
    private(set) var verified = false
    private(set) var hasLoaded = false
    private(set) var acknowledgedWrites: [String] = []
    private(set) var completed = false
    private(set) var isBackgrounded = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var drainingRead: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var draftRevision = UUID()
    @ObservationIgnored private var preparedRevision: UUID?
    @ObservationIgnored private var plan: MobileElasticsearchPlan?
    var isBusy: Bool { isLoading || isPreparing || isSubmitting || isVerifying }
    var canSubmit: Bool { plan != nil && preparedRevision == draftRevision && !owner.safetyLock.isEnabled && !isBusy && !needsVerification && !isBackgrounded && !completed }
    var selection: WorkspaceDatabaseObjectSelection? { object.map { .init(databaseName: "Elasticsearch", objectName: $0.name, kind: $0.kind) } }
    init(owner: MobileElasticsearchWorkspace, kind: Kind, object: WorkspaceDatabaseObject?, reference: WorkspaceDocumentReference?) {
        self.owner = owner; self.kind = kind; self.object = object; self.reference = reference
        name = kind == .deleteIndex || kind == .aliases ? "" : object?.name ?? ""; documentID = reference?.id ?? ""; routing = reference?.routing ?? ""
    }
    func invalidate() { draftRevision = UUID(); plan = nil; preview = nil; preparedRevision = nil }
    @discardableResult func reload() -> Task<Void, Never>? {
        if needsVerification { return verify() }
        guard !isBusy, !isBackgrounded, !completed else { return nil }
        isLoading = true; message = nil; generation = UUID(); let token = generation
        let task = Task { [weak self, owner = owner] in
            defer { _ = owner }
            guard let self else { return }
            do {
                let service = try await owner.ready()
                switch kind {
                case .document:
                    guard let reference else { throw MobileElasticsearchFailure.unavailable }
                    let snapshot = try await service.fetchDocument(reference, maximumByteCount: 1_048_576)
                    try validateRead(token)
                    document = snapshot; mode = "replace"; source = String(decoding: snapshot.sourceJSON, as: UTF8.self); raw = source
                case .mapping:
                    guard let object else { throw MobileElasticsearchFailure.unavailable }
                    let snapshot = try await service.fetchMappingSnapshot(.init(resource: object.name, kind: object.kind))
                    try validateRead(token); mapping = snapshot; mappingIsNew = true; mappingPath = "[\"properties\",\"new_field\"]"; raw = String(decoding: snapshot.rawJSON, as: UTF8.self)
                    source = "{\"type\":\"keyword\"}"
                case .settings:
                    guard let selection else { throw MobileElasticsearchFailure.unavailable }
                    let snapshot = try await WorkspaceIndexSettingsWorker().load(selection) { try await service.executeRequest($0) }
                    try validateRead(token); settings = snapshot; raw = String(decoding: snapshot.rawJSON, as: UTF8.self)
                    replicas = snapshot.editableIndex?.effective("index.number_of_replicas") ?? ""; secondary = snapshot.editableIndex?.effective("index.refresh_interval") ?? "1s"
                case .aliases:
                    guard let selection else { throw MobileElasticsearchFailure.unavailable }
                    let worker = WorkspaceElasticsearchAliasWorker()
                    let snapshot = try await worker.load(selection) { try await service.executeRequest($0) }
                    let rows = await worker.rows(snapshot)
                    try validateRead(token); aliases = snapshot; aliasRows = rows; name = selection.kind == .elasticsearchAlias ? selection.objectName : ""; secondary = selection.kind == .elasticsearchIndex ? selection.objectName : ""; raw = String(decoding: snapshot.rawJSON, as: UTF8.self)
                case .templates:
                    let worker = WorkspaceElasticsearchIndexTemplateWorker()
                    let response = try await service.executeRequest(worker.listRequest)
                    let snapshots = try await worker.templates(from: response)
                    try validateRead(token); templates = snapshots; raw = String(decoding: response.body, as: UTF8.self)
                    if let baseline = templateBaseline { templateBaseline = snapshots.first { $0.name == baseline.name }; name = templateBaseline?.name ?? ""; source = templateBaseline?.source ?? "{}"; mode = "save" }
                    if templateBaseline == nil { name = ""; source = "{\"index_patterns\":[\"logs-*\"],\"template\":{\"settings\":{},\"mappings\":{}}}" }
                default: try validateRead(token)
                }
                hasLoaded = true
            } catch {
                if token == generation, !(error is CancellationError) { message = error.localizedDescription }
            }
            guard token == generation else { return }; isLoading = false; self.task = nil
        }
        self.task = task; return task
    }
    private func validateRead(_ token: UUID) throws { try Task.checkCancellation(); guard generation == token, !isBackgrounded else { throw CancellationError() } }
    func selectTemplate(_ template: WorkspaceElasticsearchIndexTemplateSnapshot?) {
        guard !isBusy, !needsVerification else { return }
        templateBaseline = template; name = template?.name ?? ""; source = template?.source ?? "{\"index_patterns\":[\"logs-*\"],\"template\":{}}"; mode = "save"
    }
    func selectMappingField(_ node: WorkspaceMappingFieldNode) {
        guard !isBusy else { return }
        mappingPath = String(decoding: (try? JSONEncoder().encode(node.path)) ?? Data(), as: UTF8.self)
        source = String(decoding: node.definitionJSON, as: UTF8.self); mappingIsNew = false
    }
    @discardableResult func prepare() -> Task<Void, Never>? {
        guard hasLoaded, !isBusy, !needsVerification, !isBackgrounded, !completed else { return nil }
        guard !owner.cellChanges.hasChanges || kind == .cellChanges else { message = "请先提交或撤销已暂存的字段修改。"; return nil }
        invalidate(); let revision = draftRevision; let token = generation
        isPreparing = true; message = nil
        let task = Task { [weak self, owner = owner] in
            defer { _ = owner }
            guard let self else { return }
            do {
                let service = try await owner.ready()
                let result = try await makePlan(service)
                let text = try await WorkspaceElasticsearchConsoleWorker().previewSource(result.requests)
                try validateRead(token)
                guard draftRevision == revision else { throw MobileElasticsearchFailure.stale }
                plan = result; preview = text; preparedRevision = revision
            } catch { if token == generation { message = error.localizedDescription } }
            if token == generation { isPreparing = false; self.task = nil }
        }
        self.task = task; return task
    }
    @discardableResult func submit() -> Task<Void, Never>? {
        guard canSubmit, let plan else { return nil }
        isSubmitting = true; message = nil; verified = false
        let revision = draftRevision
        let task = Task { [weak self, owner = owner] in
            defer { _ = owner }
            guard let self else { return }
            var sent = false
            do {
                let service = try await owner.ready()
                try await plan.preflight(service)
                guard revision == draftRevision, !isBackgrounded, !owner.safetyLock.isEnabled else { throw MobileElasticsearchFailure.stale }
                try Task.checkCancellation(); sent = true
                let receipt = try await plan.send(service)
                if kind == .cellChanges { owner.cellChanges.discard() }
                completed = true; preview = nil; self.plan = nil; message = "服务器已确认完成。\n" + receipt; owner.didWrite()
            } catch {
                if let partial = error as? MobileElasticsearchBatchFailure {
                    acknowledgedWrites = partial.acknowledged; needsVerification = true; message = partial.localizedDescription + " 本批次不重放，请核实后结束。"
                } else if sent, !MobileElasticsearchFailure.isDefinite(error) { needsVerification = true; message = MobileElasticsearchFailure.uncertain.localizedDescription }
                else { message = error.localizedDescription; invalidate() }
            }
            isSubmitting = false; self.task = nil
            if isBackgrounded { owner.cancel() }
        }
        self.task = task; return task
    }
    @discardableResult func verify() -> Task<Void, Never>? {
        guard needsVerification, !isBusy, !isBackgrounded, let plan else { return nil }
        isVerifying = true; message = nil; verified = false; let token = generation
        let task = Task { [weak self, owner = owner] in
            defer { _ = owner }
            guard let self else { return }
            do {
                let service = try await owner.ready()
                let text = try await plan.verification(service)
                try validateRead(token)
                raw = text; verified = true; message = "已读取当前服务器状态，请核对后明确结束；此读取不证明原请求是否成功。"
            } catch { if token == generation { message = error.localizedDescription } }
            if token == generation { isVerifying = false; self.task = nil }
        }
        self.task = task; return task
    }
    func finishVerification() { guard verified, !isBusy else { return }; needsVerification = false; completed = true; if kind == .cellChanges { owner.cellChanges.discard() }; owner.didWrite(); invalidate() }
    func cancelRead() { guard !isSubmitting else { return }; if let task { drainingRead = task }; generation = UUID(); task?.cancel(); task = nil; isLoading = false; isPreparing = false; isVerifying = false; verified = false; invalidateUnlessUncertain() }
    private func invalidateUnlessUncertain() { if !needsVerification { invalidate() } }
    func setBackgrounded(_ value: Bool) { isBackgrounded = value; if value { owner.safetyLock.enable(); cancelRead() } }
    func close() { guard !isBusy, !needsVerification else { return }; cancelRead(); if owner.fullscreenAction === self { owner.fullscreenAction = nil } else { owner.action = nil } }
    @discardableResult func simulate() -> Task<Void, Never>? {
        guard !isBusy, !isBackgrounded else { return nil }
        let pending: Task<Void, Never> = Task { [weak self, owner = owner] in
            defer { _ = owner }
            await self?.runSimulation()
        }
        task = pending; return pending
    }
    func runSimulation() async {
        guard !isBusy, !isBackgrounded else { return }
        isLoading = true; message = nil; let token = generation, input = name
        defer { if token == generation { isLoading = false; task = nil } }
        do {
            let worker = WorkspaceElasticsearchTemplateSimulationWorker()
            let request = try await worker.request(indexName: input)
            let service = try await owner.ready()
            let response = try await service.executeRequest(request)
            let templates = try await service.executeRequest(.init(method: .get, path: "/_index_template"))
            let result = try await worker.result(indexName: input, response: response, templates: templates)
            try validateRead(token)
            guard input == name else { throw MobileElasticsearchFailure.stale }
            raw = result.response; message = result.error ?? ("匹配模板：" + result.matchedTemplates.joined(separator: ", "))
        } catch { if token == generation { message = error.localizedDescription } }
    }

    func updateAlias(_ id: UUID, writeIndex: String) {
        guard let index = aliasRows.firstIndex(where: { $0.id == id }) else { return }
        aliasRows[index].binding.isWriteIndex = writeIndex == "default" ? nil : writeIndex == "yes"
    }
    func toggleAlias(_ id: UUID) {
        guard let index = aliasRows.firstIndex(where: { $0.id == id }) else { return }
        aliasRows[index].isRemoved.toggle()
    }
    func addAlias() {
        do {
            let options = try WorkspaceMappingCodec.object(Data(source.utf8))
            guard options["is_write_index"] == nil else { throw MobileElasticsearchFailure.rejected("写入索引请使用绑定行内的选择器。") }
            aliasRows.append(.init(id: UUID(), original: nil, binding: .init(indexName: secondary, aliasName: name, isWriteIndex: nil, optionsJSON: try WorkspaceMappingCodec.json(options)), isRemoved: false))
        } catch { message = error.localizedDescription }
    }

    func loadField(_ name: String) {
        guard !isBusy, let snapshot = document else { return }
        fieldName = name
        let token = generation
        Task { [weak self, owner = owner] in
            defer { _ = owner }
            guard let self else { return }
            do {
                let initial = try await owner.cellChanges.initialValue(snapshot: snapshot, fieldName: name)
                guard fieldName == name, token == generation, !isBackgrounded else { return }
                fieldText = initial.text
                fieldNull = initial.mutation == .null
            } catch { message = error.localizedDescription }
        }
    }
    func stageField() {
        guard !isBusy, let snapshot = document, !fieldName.isEmpty else { return }
        do {
            var edits = owner.cellChanges.entries[snapshot.reference]?.edits ?? [:]
            edits[fieldName] = fieldNull ? .null : .text(fieldText)
            let service = owner.session
            try owner.cellChanges.stage(snapshot: snapshot, edits: edits) { draft in
                guard let service else { throw MobileElasticsearchFailure.unavailable }
                return try await service.prepareDocumentPartialUpdate(draft)
            }
            owner.didStage()
            Task { [weak workspace = owner] in
                guard let workspace else { return }
                await workspace.cellChanges.waitForValidation(); workspace.didStage()
            }
            message = "字段已暂存；可关闭后继续修改其他文档，再从待提交修改统一预览。"
        } catch { message = error.localizedDescription }
    }
    func discardCellChanges() { guard !isBusy, !needsVerification else { return }; owner.cellChanges.discard(); owner.didStage(); invalidate() }

    func waitForReadCancellation() async { await drainingRead?.value }

    func openInConsole() {
        guard !isBusy, !needsVerification, let preview, owner.fullscreenAction !== self else { return }
        let workspace = owner
        close(); workspace.console.source = preview; workspace.console.scope = "all"; workspace.console.selection = .init(location: 0, length: 0); workspace.showsConsole = true
    }

}
