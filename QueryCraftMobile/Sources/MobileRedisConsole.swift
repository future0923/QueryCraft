import Foundation
import Observation
import QueryCraftMobileCore

@MainActor @Observable final class MobileRedisConsole {
    let safetyLock = WorkspaceSafetyLock()
    private(set) var database: Int
    private(set) var needsVerification = false
    private(set) var transactionOpen = false
    private(set) var isBackgrounded = false
    private(set) var isVerifying = false
    private(set) var isClosingConnection = false
    @ObservationIgnored private var connectionCloseTask: Task<Void, Never>?
    @ObservationIgnored private var closeGeneration = UUID()
    private(set) var preview: String?
    private(set) var message: String?
    private(set) var document: WorkspaceRedisCommandDocumentModel!
    @ObservationIgnored private let service: any MobileRedisConsoleServing
    @ObservationIgnored private var preparedSource: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored var didWrite: (() -> Void)?
    init(profile: MobileConnectionProfile, password: String?, database: Int, keys: [RedisKeyReference], injectedService: (any MobileRedisConsoleServing)? = nil) {
        self.database = database
        service = injectedService ?? MobileRedisConsoleService(profile: profile, password: password, database: database)
        document = .init(title: "Redis 命令", databaseIndex: { [weak self] in self?.database ?? database }, availableKeys: { keys }, isSafetyLockEnabled: { [weak self] in self?.safetyLock.isEnabled ?? true }, loadSuggestions: { [service] request in try await service.suggestions(request) }, replyByteLimit: 65_536, transcriptByteLimit: 4_194_304, historyByteLimit: 1_048_576, executeCommand: { [weak self] invocation, _ in
            guard let self else { throw RedisKeyEditError.unavailable }
            return try await self.execute(invocation)

        })
    }
    private func execute(_ invocation: RedisCommandInvocation) async throws -> RedisCommandResult {
        guard !needsVerification, !isBackgrounded else { throw RedisKeyEditError.unavailable }
            let writes = RedisCommandCatalog.entry(named: invocation.arguments.first)?.isReadOnly != true
            guard !writes || !self.safetyLock.isEnabled else { throw RedisKeyEditError.safetyLockEnabled }
            do {
                let result = try await service.execute(invocation)
                self.database = result.database; self.transactionOpen = result.transactionOpen
                if self.isBackgrounded {
                    await service.close(); self.transactionOpen = false
                    self.message = "会话已关闭，未 EXEC 的事务已丢弃。"
                }
                if writes { self.didWrite?() }
                return result.result
            } catch {
                self.transactionOpen = false
                if case MobileRedisMutationError.unverified = error { self.needsVerification = true }
                throw error
            }
    }
    var canRun: Bool { !document.isExecuting && !needsVerification && !isBackgrounded && !isVerifying && !isClosingConnection }
    var canClose: Bool { !document.isExecuting && !needsVerification && !isVerifying && !isClosingConnection }
    func prepare() {
        guard canRun else { return }
        preview = nil; preparedSource = nil; message = nil
        guard !document.requiresSafetyLockDisable || !safetyLock.isEnabled else { message = RedisKeyEditError.safetyLockEnabled.localizedDescription; return }
        let parsed = RedisCommandTokenizer.tokenize(document.source)
        guard !parsed.hasUnterminatedQuote, !parsed.arguments.isEmpty else { message = "命令为空或引号未闭合。"; return }
        guard document.source.utf8.count <= 1_048_576 else { message = "单条输入限 1 MiB。"; return }
        preparedSource = document.source
        preview = parsed.arguments.map { RedisBinaryCommandPreviewFormatter.escaped(.init(utf8: $0)) }.joined(separator: " ")
    }
    @discardableResult func run() -> Task<Void, Never>? {
        guard canRun else { return nil }
        guard document.source.utf8.count <= 1_048_576 else { message = "单条输入限 1 MiB。"; return nil }
        if document.requiresSafetyLockDisable {
            guard !safetyLock.isEnabled, preparedSource == document.source else { preview = nil; preparedSource = nil; message = "请先解锁并预览当前命令。"; return nil }
        }
        preview = nil; preparedSource = nil; message = nil
        return document.run()
    }
    @discardableResult func verify() -> Task<Void, Never>? {
        guard !document.isExecuting, !isBackgrounded, !isVerifying, !isClosingConnection else { return nil }
        isVerifying = true; let token = generation
        return Task { [weak self, service] in
            do {
                try await service.verifyConnection()
                guard let self, self.generation == token else { return }
                self.isVerifying = false; self.needsVerification = false; self.transactionOpen = false
                self.message = "连接已重新核实。未知命令不会重放，请查询实际数据确认其影响。"
            } catch {
                guard let self, self.generation == token else { return }
                self.isVerifying = false; self.message = error.localizedDescription
            }
        }
    }
    func setBackgrounded(_ value: Bool) {
        isBackgrounded = value
        if value {
            safetyLock.enable(); preview = nil; preparedSource = nil; generation = UUID(); isVerifying = false
            // Do not cancel an in-flight write: observe its actual reply before closing the session.
            if !document.isExecuting {
                transactionOpen = false
                isClosingConnection = true; closeGeneration = UUID(); let closeToken = closeGeneration
                message = "正在关闭后台会话…"
                connectionCloseTask = Task { [weak self, service] in
                    await service.close()
                    guard let self, self.closeGeneration == closeToken else { return }
                    self.isClosingConnection = false
                    self.message = "会话已关闭，未 EXEC 的事务已丢弃。"
                }
            }
        }
    }
    func close() async {
        guard !document.isExecuting, !needsVerification, !isVerifying else { return }
        isClosingConnection = true
        let pending = connectionCloseTask
        closeGeneration = UUID(); let token = closeGeneration
        await pending?.value
        document.stop(); await service.close()
        guard closeGeneration == token else { return }
        transactionOpen = false; isClosingConnection = false
        preview = nil; preparedSource = nil; document.updateSource("")
    }
}
