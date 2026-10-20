import CLibPQ
import QueryCraftFeature
import Testing
@testable import QueryCraftPostgreSQLDriver

struct PostgreSQLTransactionStateTests {
    @Test func idleConnectionReportsNoActiveTransaction() throws {
        #expect(try LibPQClient.transactionState(status: PQTRANS_IDLE) == .autoCommit)
    }

    @Test(arguments: [PQTRANS_INTRANS, PQTRANS_INERROR])
    func openAndFailedTransactionsRemainAvailableForRollback(_ status: PGTransactionStatusType) throws {
        #expect(try LibPQClient.transactionState(status: status) == .inTransaction)
    }

    @Test(arguments: [PQTRANS_ACTIVE, PQTRANS_UNKNOWN])
    func unavailableStatusDoesNotInventASuccessfulTransactionState(_ status: PGTransactionStatusType) {
        #expect(throws: WorkspaceSessionError.self) {
            try LibPQClient.transactionState(status: status)
        }
    }
}
