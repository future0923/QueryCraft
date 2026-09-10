struct QueryExecutionOptions: Equatable, Sendable {
    let statementTimeout: Duration?
    let maximumResultRows: Int?

    static let unlimited = QueryExecutionOptions(
        statementTimeout: nil,
        maximumResultRows: nil
    )
}
