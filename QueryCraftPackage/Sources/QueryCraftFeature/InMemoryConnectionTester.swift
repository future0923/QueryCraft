struct InMemoryConnectionTester: ConnectionTester {
    func test(_ configuration: DatabaseConnectionConfiguration) async throws {}
}
