public protocol DatabaseSchemaEditingProvider: Sendable {
    var descriptor: WorkspaceDatabaseSchemaEditingDescriptor { get }

    func makeExecutionPlan(
        for changes: WorkspaceDatabaseSchemaChangeSet
    ) throws -> WorkspaceDatabaseSchemaExecutionPlan

    func makeExecutionPlan(
        for mutation: WorkspaceDatabaseTableMutation
    ) throws -> WorkspaceDatabaseSchemaExecutionPlan
}
