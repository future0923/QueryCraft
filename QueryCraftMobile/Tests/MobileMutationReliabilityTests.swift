import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileMutationReliabilityTests {
    private func configuration() throws -> MariaDBTransportConfiguration {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init))
        return .init(host: "127.0.0.1", port: port, username: "proof_writer", password: "querycraft-proof-writer", database: "querycraft_ios_edit", tlsMode: .required)
    }
    private func fixture(_ table: String, mode: FaultConnection.Mode) async throws -> (MobileTableChanges, FaultConnection) {
        let config = try configuration(), object = MobileDatabaseObject(database: "querycraft_ios_edit", name: table, kind: .table, comment: "")
        let service = MobileMySQLService(), columns = try await service.columns(configuration: config, object: object)
        let page = try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 100, sortColumn: nil, ascending: true, filter: .empty)
        let connection = FaultConnection(configuration: config, mode: mode)
        let changes = MobileTableChanges(object: object, metadata: columns, configuration: config, safetyLock: WorkspaceSafetyLock(),
            service: MobileDataMutationService(makeConnection: { _ in connection }))
        try changes.stage(changes.request(page: page, row: 0, column: 1), text: "changed", mode: .value)
        changes.safetyLock.disable()
        return (changes, connection)
    }
    private func serverName(_ table: String) async throws -> String? {
        try await MobileMariaDBExecutor().execute(configuration: configuration(), sql: "SELECT name FROM `\(table)` WHERE id=1").rows.first?.first ?? nil
    }

    @Test func backgroundAfterWriteRollsBackEvenWithLockEnabledAndRetainsDraft() async throws {
        let (changes, connection) = try await fixture("reliability_cancel", mode: .holdAfterWrite)
        let operation = try #require(changes.submit())
        #expect(await connection.waitForGate())
        changes.interruptSubmission()
        #expect(changes.isSubmitting); #expect(changes.safetyLock.isEnabled); #expect(changes.submit() == nil)
        await connection.release(); await operation.value
        #expect(!changes.isSubmitting); #expect(changes.hasChanges); #expect(!changes.needsVerification)
        #expect(changes.message?.contains("中断") == true)
        #expect(await connection.statements.contains("ROLLBACK")); #expect(!(await connection.statements.contains("COMMIT")))
        #expect(try await serverName("reliability_cancel") == "before")
        // Only an explicit new submission may retry, with a newly unlocked lock.
        changes.safetyLock.disable(); await changes.submit()?.value
        #expect(!changes.hasChanges); #expect(try await serverName("reliability_cancel") == "changed")
    }

    @Test func lostCommitAcknowledgementKeepsDraftButBlocksAllRepeatWrites() async throws {
        let (changes, connection) = try await fixture("reliability_commit", mode: .loseCommitAcknowledgement)
        await changes.submit()?.value
        #expect(try await serverName("reliability_commit") == "changed", "Server committed even though the acknowledgement was lost")
        #expect(changes.hasChanges); #expect(changes.needsVerification); #expect(!changes.canSubmit)
        #expect(changes.message == MobileDataMutationError.uncertainCommit.localizedDescription)
        #expect(changes.submit() == nil)
        #expect(await connection.statements.filter { $0 == "COMMIT" }.count == 1)
        changes.interruptSubmission(); changes.safetyLock.disable()
        #expect(changes.submit() == nil, "Returning foreground or unlocking cannot clear uncertain outcome")
        var verificationRequested = false
        changes.didDiscardUncertain = { verificationRequested = true }
        changes.discard(); #expect(verificationRequested); #expect(!changes.hasChanges)
    }

    @Test func cancellationWithCommitInFlightIsUncertainEvenWhenServerCommitted() async throws {
        let (changes, connection) = try await fixture("reliability_inflight", mode: .holdCommitAcknowledgement)
        let operation = try #require(changes.submit()); #expect(await connection.waitForGate())
        changes.interruptSubmission(); await connection.release(); await operation.value
        #expect(try await serverName("reliability_inflight") == "changed")
        #expect(changes.needsVerification); #expect(changes.hasChanges); #expect(changes.submit() == nil)
        #expect(await connection.statements.filter { $0 == "COMMIT" }.count == 1)
    }

    @Test func disconnectedBeforeCommitRollsBackWithoutClaimingUnknownCommit() async throws {
        let (changes, connection) = try await fixture("reliability_disconnect", mode: .disconnectAfterWrite)
        await changes.submit()?.value
        #expect(changes.hasChanges); #expect(!changes.needsVerification); #expect(changes.message != nil)
        #expect(try await serverName("reliability_disconnect") == "before")
        #expect(!(await connection.statements.contains("COMMIT")))
    }
}

private actor FaultConnection: MobileMutationConnection {
    enum Mode { case holdAfterWrite, loseCommitAcknowledgement, holdCommitAcknowledgement, disconnectAfterWrite }
    private let client: MobileMariaDBMutationConnection
    private let mode: Mode
    private var fired = false, waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var statements: [String] = []
    init(configuration: MariaDBTransportConfiguration, mode: Mode) {
        client = .init(client: MariaDBClient(configuration: configuration)); self.mode = mode
    }
    func connect() async throws { try await client.connect() }
    func close() async { await client.close() }
    func query(_ sql: String, bindings: [WorkspaceDatabaseDataCell]) async throws -> CDatabaseQueryResult {
        statements.append(sql)
        let result = try await client.query(sql, bindings: bindings)
        guard !fired else { return result }
        if sql.hasPrefix("UPDATE") {
            if mode == .disconnectAfterWrite {
                fired = true; await client.close(); throw LostConnection.expected
            }
            if mode == .holdAfterWrite {
                fired = true; waiting = true; await withCheckedContinuation { continuation = $0 }
                try Task.checkCancellation()
            }
        }
        if sql == "COMMIT" {
            if mode == .loseCommitAcknowledgement {
                fired = true; await client.close(); throw LostConnection.expected
            }
            if mode == .holdCommitAcknowledgement {
                fired = true; waiting = true; await withCheckedContinuation { continuation = $0 }
                try Task.checkCancellation()
            }
        }
        return result
    }
    func waitForGate() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !waiting, ContinuousClock.now < deadline { await Task.yield() }
        return waiting
    }
    func release() { continuation?.resume(); continuation = nil; waiting = false }
    private enum LostConnection: Error { case expected }
}
