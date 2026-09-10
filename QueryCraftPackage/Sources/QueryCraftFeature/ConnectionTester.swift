protocol ConnectionTester: Sendable {
    func test(_ configuration: DatabaseConnectionConfiguration) async throws
}
