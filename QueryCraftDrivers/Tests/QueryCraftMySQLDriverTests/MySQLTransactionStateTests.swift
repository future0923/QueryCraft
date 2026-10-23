import CMariaDB
import QueryCraftFeature
import QueryCraftMariaDBTransportV4
import Testing

struct MySQLTransactionStateTests {
    @Test(arguments: [
        UInt32(0),
        UInt32(SERVER_STATUS_AUTOCOMMIT),
        UInt32(SERVER_STATUS_AUTOCOMMIT | SERVER_STATUS_NO_BACKSLASH_ESCAPES),
    ])
    func completedStatementsWithoutAnActiveTransactionReportIdle(_ flags: UInt32) {
        #expect(MariaDBClient.transactionState(serverStatus: flags) == .autoCommit)
    }

    @Test(arguments: [
        UInt32(SERVER_STATUS_IN_TRANS),
        UInt32(SERVER_STATUS_IN_TRANS | SERVER_STATUS_AUTOCOMMIT),
        UInt32(SERVER_STATUS_IN_TRANS | SERVER_STATUS_IN_TRANS_READONLY),
    ])
    func explicitAndImplicitTransactionsUseServerFlags(_ flags: UInt32) {
        #expect(MariaDBClient.transactionState(serverStatus: flags) == .inTransaction)
    }
}
