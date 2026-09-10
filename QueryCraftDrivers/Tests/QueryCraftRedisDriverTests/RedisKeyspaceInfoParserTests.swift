import Testing
@testable import QueryCraftRedisDriver

struct RedisKeyspaceInfoParserTests {
    @Test
    func parsesKeyCountsAndIgnoresUnrelatedLines() {
        let info = """
        # Keyspace
        db0:keys=17,expires=1,avg_ttl=12345
        db10:keys=32,expires=0,avg_ttl=0
        malformed
        """

        #expect(RedisKeyspaceInfoParser.parse(info) == [0: 17, 10: 32])
    }

    @Test
    func emptyKeyspaceProducesNoObservedDatabaseRows() {
        #expect(RedisKeyspaceInfoParser.parse("# Keyspace\n") == [:])
    }
}
