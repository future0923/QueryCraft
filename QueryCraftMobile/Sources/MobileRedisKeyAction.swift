import Foundation
import Observation
import QueryCraftMobileCore

enum MobileRedisKeyActionError: LocalizedError {
    case keyNameTooLarge
    var errorDescription: String? { "移动端新建或重命名的键名限 64 KiB（UTF-8）。" }
}

enum MobileRedisKeyOperation: Equatable, Sendable {
    case create(RedisKeyCreationPlan)
    case rename(RedisKeyRenamePlan)
    case metadata(RedisKeyMetadataMutationPlan)
    var destination: RedisKeyReference {
        switch self {
        case .create(let plan): plan.reference
        case .metadata(let plan): plan.reference
        case .rename(let plan): .init(databaseIndex: plan.reference.databaseIndex, name: plan.newName, type: plan.reference.type)
        }
    }
    var references: [RedisKeyReference] {
        if case .rename(let plan) = self { return [plan.reference, destination] }
        return [destination]
    }
    var preview: String {
        let commands: [RedisCommandInvocation]
        switch self {
        case .create(let plan): commands = plan.commands
        case .metadata(let plan): commands = [plan.command]
        case .rename(let plan): commands = [plan.command]
        }
        return commands.map { $0.arguments.map { RedisBinaryCommandPreviewFormatter.escaped(.init(utf8: $0)) }.joined(separator: " ") }.joined(separator: "\n")
    }
}

struct MobileRedisKeyStatus: Sendable {
    let reference: RedisKeyReference
    // -2 means absent, -1 means persistent, matching Redis PTTL.
    let ttl: Int64
    var exists: Bool { ttl != -2 }
}

protocol MobileRedisKeyActing: Sendable {
    func perform(_ operation: MobileRedisKeyOperation) async throws
    func inspect(_ references: [RedisKeyReference]) async throws -> [MobileRedisKeyStatus]
}

struct MobileRedisKeyActionService: MobileRedisKeyActing {
    let profile: MobileConnectionProfile
    let password: String?
    private func client(database: Int) throws -> RedisClient {
        guard profile.driver == .redis, profile.tlsMode == .disabled, database >= 0 else { throw MobileRedisMutationError.unsupported }
        return RedisClient(configuration: .init(host: profile.host, port: profile.port, username: profile.username, password: password, databaseIndex: database))
    }
    func perform(_ operation: MobileRedisKeyOperation) async throws {
        switch operation {
        case .metadata(let plan):
            try await MobileRedisMutationService(profile: profile, password: password).apply(plan.optimisticRequest)
        case .create(let plan):
            try await MobileRedisMutationService(profile: profile, password: password).apply(plan.optimisticRequest)
        case .rename(let plan):
            guard plan.newName != plan.reference.name else { return }
            let client = try client(database: plan.reference.databaseIndex)
            do {
                try await client.connect(); try Task.checkCancellation()
                let reply: RedisReplyValue
                do { reply = try await client.execute(plan.command.arguments) }
                catch { throw MobileRedisMutationError.unverified(error.localizedDescription) }
                // A server error or integer 0 proves RENAMENX did not rename.
                if case .error(let message) = reply { throw RedisClientError(message: message) }
                if case .integer(let value) = reply, value == 0 || value == 1 {
                    _ = try plan.result(for: reply)
                } else { throw MobileRedisMutationError.unverified("RENAMENX 返回了无效回执。") }
                await client.close()
            } catch { await client.close(); throw error }
        }
    }
    func inspect(_ references: [RedisKeyReference]) async throws -> [MobileRedisKeyStatus] {
        guard let first = references.first, references.allSatisfy({ $0.databaseIndex == first.databaseIndex }) else { throw RedisWorkspaceError.unavailable }
        let client = try client(database: first.databaseIndex)
        do {
            try await client.connect()
            var result: [MobileRedisKeyStatus] = []
            for reference in references {
                try Task.checkCancellation()
                let typeReply = try await client.execute(["TYPE", reference.name])
                let ttlReply = try await client.execute(["PTTL", reference.name])
                if case .error(let message) = typeReply { throw RedisClientError(message: message) }
                if case .error(let message) = ttlReply { throw RedisClientError(message: message) }
                guard let type = typeReply.stringValue, let ttl = ttlReply.integerValue, ttl >= -2 else { throw RedisWorkspaceError.invalidReply("TYPE/PTTL") }
                result.append(.init(reference: .init(databaseIndex: reference.databaseIndex, name: reference.name, type: ttl == -2 ? .none : RedisKeyType(rawValue: type) ?? .unknown), ttl: ttl))
            }
            try Task.checkCancellation(); await client.close(); return result
        } catch { await client.close(); throw error }
    }
}

@MainActor @Observable final class MobileRedisKeyAction: Identifiable {
    enum MetadataAction { case delete, expiration }
    enum Mode { case create(RedisKeyType), rename(RedisKeyReference), metadata(RedisKeyReference, MetadataAction) }
    let id = UUID()
    let mode: Mode
    let database: Int
    let safetyLock = WorkspaceSafetyLock()
    var name: String
    var text = ""
    var rows: [RedisKeyEditableRow] = []
    var expirationMode = RedisKeyExpirationMode.persistent
    var ttl = ""
    private(set) var preview: String?
    private(set) var message: String?
    private(set) var isSubmitting = false
    private(set) var isLoading = false
    private(set) var isBackgrounded = false
    private(set) var needsVerification = false
    private(set) var statuses: [MobileRedisKeyStatus]?
    private(set) var submitted: MobileRedisKeyOperation?
    private(set) var succeeded = false
    @ObservationIgnored private let service: any MobileRedisKeyActing
    @ObservationIgnored private var prepared: MobileRedisKeyOperation?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    init(mode: Mode, database: Int, service: any MobileRedisKeyActing) {
        self.mode = mode; self.database = database; self.service = service
        switch mode {
        case .rename(let reference), .metadata(let reference, _): name = reference.name
        case .create: name = ""
        }
    }
    var type: RedisKeyType {
        if let metadata { return metadata.reference.type }
        return switch mode { case .create(let type): type; case .rename(let reference), .metadata(let reference, _): reference.type }
    }
    var isCreation: Bool { if case .create = mode { true } else { false } }
    var isMetadata: Bool { if case .metadata = mode { true } else { false } }
    var isExpiration: Bool { if case .metadata(_, .expiration) = mode { true } else { false } }
    var isDeletion: Bool { if case .metadata(_, .delete) = mode { true } else { false } }
    var title: String { isMetadata ? (isExpiration ? "修改整键 TTL" : "删除 Redis 键") : isCreation ? "新建 Redis 键" : "重命名 Redis 键" }
    private(set) var metadata: MobileRedisKeyStatus?
    var canEdit: Bool { !isSubmitting && submitted == nil && !isBackgrounded && (!isMetadata || metadata?.exists == true) && !isLoading }
    var canClose: Bool { !isSubmitting && !needsVerification }
    @discardableResult func loadMetadata() -> Task<Void, Never>? {
        guard case .metadata(let reference, _) = mode, !isBackgrounded, !isSubmitting, submitted == nil else { return nil }
        readTask?.cancel(); generation = UUID(); let token = generation
        isLoading = true; message = nil; prepared = nil; preview = nil
        let task = Task { [weak self, service] in
            do {
                let states = try await service.inspect([reference]); try Task.checkCancellation()
                guard let status = states.first else { throw RedisWorkspaceError.invalidReply("TYPE/PTTL") }
                guard let self, self.generation == token else { return }
                self.metadata = status; self.isLoading = false; self.readTask = nil
                self.expirationMode = status.ttl >= 0 ? .expires : .persistent
                self.ttl = status.ttl >= 0 ? String(status.ttl) : ""
                if !status.exists { self.message = "键已不存在。" }
            } catch {
                guard let self, self.generation == token else { return }
                self.isLoading = false; self.readTask = nil; self.message = error.localizedDescription
            }
        }
        readTask = task; return task
    }
    var hasDraft: Bool {
        if isDeletion { return false }
        if isExpiration {
            guard let metadata else { return false }
            return expirationMode != (metadata.ttl >= 0 ? .expires : .persistent) || (expirationMode == .expires && ttl != String(metadata.ttl))
        }
        if case .rename(let reference) = mode { return name != reference.name }
        return !name.isEmpty || !text.isEmpty || !rows.isEmpty || expirationMode != .persistent
    }
    var verifiedDestination: RedisKeyReference? {
        guard succeeded, let destination = submitted?.destination else { return nil }
        return statuses?.first { $0.reference == destination && $0.exists }?.reference
    }
    private func operation() throws -> MobileRedisKeyOperation {
        guard isMetadata || name.utf8.count <= 65_536 else { throw MobileRedisKeyActionError.keyNameTooLarge }
        guard rows.count <= 1_000, text.utf8.count + rows.reduce(0, { $0 + $1.firstValue.utf8.count + $1.secondValue.utf8.count }) <= 1_048_576 else { throw MobileRedisMutationError.tooLarge }
        switch mode {
        case .metadata(let reference, let action):
            let actual = metadata?.reference ?? reference
            if action == .delete { return .metadata(.delete(actual)) }
            return .metadata(try .expiration(actual, mode: expirationMode, milliseconds: ttl))
        case .create(let type): return .create(try .make(databaseIndex: database, name: name, type: type, stringValue: text, rows: rows, expirationMode: expirationMode, ttlMillisecondsText: ttl))
        case .rename(let reference): return .rename(try .make(reference: reference, proposedName: name))
        }
    }
    func addRow() {
        guard canEdit, rows.count < 1_000 else { return }
        rows.append(.init(isNew: true, firstValue: "", secondValue: type == .sortedSet ? "0" : ""))
    }
    func removeRow(_ id: UUID) {
        guard canEdit else { return }
        rows.removeAll { $0.id == id }
    }
    func prepare() {
        guard canEdit else { return }
        prepared = nil; preview = nil; message = nil
        do {
            guard !safetyLock.isEnabled else { throw RedisKeyEditError.safetyLockEnabled }
            if isExpiration && !hasDraft { message = "到期方式和 TTL 未改变。"; return }
            let operation = try operation()
            if case .rename(let plan) = operation, plan.newName == plan.reference.name { message = "名称未改变。"; return }
            prepared = operation; preview = operation.preview
        } catch { message = error.localizedDescription }
    }
    @discardableResult func submit() -> Task<Void, Never>? {
        guard canEdit, !safetyLock.isEnabled, let prepared else { return nil }
        do {
            guard try operation() == prepared else { self.prepared = nil; preview = nil; message = "草稿已改变，请重新预览。"; return nil }
        } catch { self.prepared = nil; preview = nil; message = error.localizedDescription; return nil }
        isSubmitting = true; self.prepared = nil; preview = nil; message = nil
        return Task { [self, service] in
            do {
                try await service.perform(prepared)
                succeeded = true; submitted = prepared; needsVerification = true; isSubmitting = false
                message = "提交成功，正在读取当前状态。"
                await verify()?.value
            } catch {
                isSubmitting = false; message = error.localizedDescription
                if case MobileRedisMutationError.unverified = error { submitted = prepared; needsVerification = true }
            }
        }
    }
    @discardableResult func verify() -> Task<Void, Never>? {
        guard !isSubmitting, !isBackgrounded, let submitted else { return nil }
        readTask?.cancel(); generation = UUID(); let token = generation
        isLoading = true
        let task = Task { [weak self, service] in
            do {
                let statuses = try await service.inspect(submitted.references); try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.statuses = statuses; self.needsVerification = false; self.isLoading = false; self.readTask = nil
                self.message = self.succeeded ? "提交成功；以下为重新读取的当前状态。" : "已读取当前状态。回执丢失，无法据此判定本次写入是否成功；请核对后关闭。"
            } catch {
                guard let self, self.generation == token else { return }
                self.isLoading = false; self.readTask = nil
                if !(error is CancellationError) { self.message = error.localizedDescription }
            }
        }
        readTask = task; return task
    }
    func setBackgrounded(_ value: Bool) {
        isBackgrounded = value
        if value {
            safetyLock.enable(); prepared = nil; preview = nil
            generation = UUID(); readTask?.cancel(); readTask = nil; isLoading = false
        } else if isMetadata && metadata == nil && submitted == nil { loadMetadata() }
    }
    func close() { guard canClose else { return }; generation = UUID(); readTask?.cancel(); readTask = nil }
}
