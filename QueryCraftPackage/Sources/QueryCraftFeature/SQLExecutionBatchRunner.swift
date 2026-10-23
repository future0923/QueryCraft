import Foundation

/// Both editors execute the preflight plan in order and stop at the first error.
enum SQLExecutionBatchRunner {
    static func run(_ statements: [SQLExecutionStatement], isolation: isolated (any Actor)? = #isolation,
                    execute: (SQLExecutionStatement) async throws -> Void) async throws {
        for statement in statements {
            try Task.checkCancellation()
            try await execute(statement)
        }
    }
}
