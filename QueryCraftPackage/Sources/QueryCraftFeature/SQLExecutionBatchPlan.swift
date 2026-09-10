struct SQLExecutionBatchPlan: Equatable, Sendable {
    let target: SQLExecutionTarget
    let statements: [SQLExecutionStatement]

    var requiresWriteAccess: Bool {
        statements.contains { $0.kind.requiresWriteAccess }
    }

    var containsUnclassifiedStatement: Bool {
        statements.contains { $0.kind == .unknown }
    }

    var requiresDangerousSQLConfirmation: Bool {
        statements.contains { $0.kind.requiresDangerousSQLConfirmation }
    }
}
