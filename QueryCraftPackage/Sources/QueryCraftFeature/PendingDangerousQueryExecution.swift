import Foundation

struct PendingDangerousQueryExecution: Identifiable {
    let id = UUID()
    let plan: SQLExecutionBatchPlan
    let policy: SQLExecutionPolicy
    let options: QueryExecutionOptions
}
