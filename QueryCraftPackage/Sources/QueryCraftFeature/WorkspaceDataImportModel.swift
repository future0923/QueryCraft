import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class WorkspaceDataImportModel {
    enum Step: Int, CaseIterable, Identifiable {
        case source, options, mapping, confirmation, execution
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .source: AppCopy.current.text("来源", "Source")
            case .options: AppCopy.current.text("选项", "Options")
            case .mapping: AppCopy.current.text("映射", "Mapping")
            case .confirmation: AppCopy.current.text("确认", "Confirm")
            case .execution: AppCopy.current.text("执行", "Execute")
            }
        }
    }
    struct SourceColumn: Identifiable, Equatable { let name: String; let index: Int; var id: String { name } }
    struct PreviewRow: Identifiable, Equatable { let id: Int; let cells: [String?] }

    let target: WorkspaceDataImportTarget
    let targetLabel: String
    let safetyLock: WorkspaceSafetyLock
    var step = Step.source
    var options = WorkspaceDataImportOptions()
    var fileURL: URL?
    private(set) var file: WorkspaceDataImportFile?
    private(set) var schema: WorkspaceDataImportSchema?
    var mapping: [String?] = []
    var batchSize = 500
    private(set) var isLoading = false
    private(set) var loadingMessage = ""
    private(set) var isRunning = false
    private(set) var isCancelling = false
    private(set) var completedRows = 0
    private(set) var outcome: WorkspaceDataImportOutcome?
    private(set) var confirmationSQL = ""
    var errorMessage = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private let authorize: WorkspaceDataImporter.Authorize

    init(target: WorkspaceDataImportTarget, targetLabel: String, safetyLock: WorkspaceSafetyLock,
         authorize: @escaping WorkspaceDataImporter.Authorize) {
        self.target = target; self.targetLabel = targetLabel; self.safetyLock = safetyLock; self.authorize = authorize
        options.sqlBackslashEscapes = target.configuration.databaseType == .mysql
    }
    var sourceColumns: [SourceColumn] { (file?.columns ?? []).enumerated().map { SourceColumn(name: $0.element, index: $0.offset) } }
    var preview: [PreviewRow] { (file?.previewRows.prefix(max(1, min(200, options.previewRows))) ?? []).enumerated().map { PreviewRow(id: $0.offset, cells: $0.element) } }
    var plan: WorkspaceDataImportPlan? {
        guard let file, let schema else { return nil }
        return WorkspaceDataImportPlan(file: file, schema: schema, mapping: mapping, batchSize: batchSize, dialect: target.dialect)
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = AppCopy.current.text("选择导入文件", "Choose Import File")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["csv", "tsv", "txt", "json", "jsonl", "ndjson", "xlsx", "xlsm", "xls", "sql"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.selectFile(url)
        }
    }

    func selectFile(_ url: URL) {
        guard !isRunning else { return }
        task?.cancel(); loadID = UUID(); isLoading = false; loadingMessage = ""
        fileURL = url; file = nil; schema = nil; mapping = []; outcome = nil; errorMessage = ""
        setFormat(WorkspaceDataImportFormat.detect(url))
        step = .options
    }

    func setFormat(_ format: WorkspaceDataImportFormat) {
        options.format = format
        options.delimiter = format == .tsv ? "\t" : ","
        options.firstDataRow = format == .json ? 1 : 2
        options.headerRow = format == .json ? 0 : 1
        options.sheetIndex = 0
    }

    func next() {
        errorMessage = ""
        switch step {
        case .source:
            if fileURL != nil { step = .options } else { chooseFile() }
        case .options: loadPreview()
        case .mapping:
            do {
                try plan?.validate(checkRows: false)
                if let plan {
                    let example = try WorkspaceDataImportFile(columns: plan.file.columns, rows: Array(plan.file.previewRows.prefix(1)))
                    let previewPlan = WorkspaceDataImportPlan(file: example, schema: plan.schema, mapping: plan.mapping, batchSize: 1, dialect: plan.dialect)
                    confirmationSQL = String(try previewPlan.statement(from: 0).sql.prefix(4000))
                    step = .confirmation
                }
            }
            catch { errorMessage = error.localizedDescription }
        case .confirmation: start()
        case .execution: break
        }
    }

    func back() {
        guard !isLoading && !isRunning, step != .execution, step.rawValue > 0 else { return }
        step = Step(rawValue: step.rawValue - 1) ?? .source
        errorMessage = ""
    }

    func loadPreview() {
        guard !isLoading, let url = fileURL else { return }
        isLoading = true; loadingMessage = AppCopy.current.text("正在读取文件并获取表结构…", "Reading the file and loading the target schema…"); errorMessage = ""
        let id = UUID(); loadID = id
        let options = options, target = target
        task = Task { [weak self] in
            do {
                async let data = WorkspaceDataImportReader().read(url: url, options: options)
                async let columns = target.loadSchema()
                let (file, schema) = try await (data, columns)
                try Task.checkCancellation()
                guard let self, self.loadID == id else { return }
                self.file = file; self.schema = schema
                self.mapping = schema.automaticMapping(file.columns)
                self.isLoading = false; self.loadingMessage = ""; self.step = .mapping
            } catch {
                guard let self, self.loadID == id else { return }
                self.isLoading = false; self.loadingMessage = ""
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func start() {
        guard !isRunning, let plan else { return }
        do { try authorize(); try plan.validate(checkRows: false) }
        catch { errorMessage = error.localizedDescription; return }
        isRunning = true; isCancelling = false; completedRows = 0; outcome = nil; errorMessage = ""; step = .execution
        let target = target, authorize = authorize
        task = Task { [weak self] in
            let outcome = await WorkspaceDataImporter().run(target: target, plan: plan, authorize: authorize) { [weak self] rows in
                await self?.updateProgress(rows)
            }
            guard let self else { return }
            self.outcome = outcome; self.isRunning = false; self.isCancelling = false
        }
    }

    func cancel() {
        if isRunning { isCancelling = true }
        task?.cancel()
    }
    func close() { task?.cancel(); loadID = UUID() }
    private func updateProgress(_ rows: Int) { completedRows = rows }
}
