import Foundation
import QueryCraftMobileCore

struct MobileRedisConsoleResult: Sendable {
    let result: RedisCommandResult
    let database: Int
    let transactionOpen: Bool
}

protocol MobileRedisConsoleServing: Sendable {
    func execute(_ invocation: RedisCommandInvocation) async throws -> MobileRedisConsoleResult
    func suggestions(_ request: RedisCommandSuggestionRequest) async throws -> [String]
    func close() async
    func verifyConnection() async throws
}

actor MobileRedisConsoleService: MobileRedisConsoleServing {
    let profile: MobileConnectionProfile
    let password: String?
    private var database: Int
    private var client: RedisClient?
    private var transactionOpen = false
    private var queued: [RedisCommandInvocation] = []
    init(profile: MobileConnectionProfile, password: String?, database: Int) {
        self.profile = profile; self.password = password; self.database = database
    }
    private func newClient() throws -> RedisClient {
        guard profile.driver == .redis, profile.tlsMode == .disabled else { throw MobileRedisMutationError.unsupported }
        return .init(configuration: .init(host: profile.host, port: profile.port, username: profile.username, password: password, databaseIndex: database))
    }
    func execute(_ invocation: RedisCommandInvocation) async throws -> MobileRedisConsoleResult {
        let active: RedisClient
        if let client { active = client }
        else { let fresh = try newClient(); try await fresh.connect(); client = fresh; active = fresh }
        try Task.checkCancellation()
        let start = ContinuousClock.now
        let reply: RedisReplyValue
        do { reply = try await active.execute(invocation.arguments) }
        catch {
            await close()
            if RedisCommandCatalog.entry(named: invocation.arguments.first)?.isReadOnly != true { throw MobileRedisMutationError.unverified(error.localizedDescription) }
            throw error
        }
        let name = invocation.arguments.first?.uppercased()
        if case .simpleString(let status) = reply, status.uppercased() == "QUEUED", transactionOpen { queued.append(invocation) }
        if name == "EXEC" {
            if case .array(let results) = reply {
                for (command, result) in zip(queued, results) {
                    if command.arguments.first?.uppercased() == "SELECT", case .simpleString("OK") = result,
                       let value = command.arguments.dropFirst().first.flatMap(Int.init) { database = value }
                }
            }
            queued = []
        }
        if case .simpleString(let status) = reply, status.uppercased() == "OK" {
            switch invocation.arguments.first?.uppercased() {
            case "SELECT": if let value = invocation.arguments.dropFirst().first.flatMap(Int.init) { database = value }
            case "MULTI": transactionOpen = true; queued = []
            case "DISCARD": transactionOpen = false; queued = []
            default: break
            }
        }
        if invocation.arguments.first?.uppercased() == "EXEC" { transactionOpen = false }
        let elapsed = start.duration(to: .now)
        return .init(result: .init(invocation: invocation, reply: reply, elapsedSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18), database: database, transactionOpen: transactionOpen)
    }
    func suggestions(_ request: RedisCommandSuggestionRequest) async throws -> [String] {
        let isolated = try newClient()
        do {
            try await isolated.connect()
            let reply = try await isolated.execute(request.invocation.arguments, databaseIndex: request.databaseIndex)
            let result = try request.candidates(from: reply); await isolated.close(); return result
        } catch { await isolated.close(); throw error }
    }
    func close() async {
        let old = client; client = nil; transactionOpen = false; queued = []
        await old?.close()
    }
    func verifyConnection() async throws {
        await close()
        let client = try newClient()
        do {
            try await client.connect()
            let reply = try await client.execute(["PING"])
            if case .error(let message) = reply { throw RedisClientError(message: message) }
            guard reply == .simpleString("PONG") else { throw RedisWorkspaceError.invalidReply("PING") }
            await client.close()
        }
        catch { await client.close(); throw error }
    }
}
