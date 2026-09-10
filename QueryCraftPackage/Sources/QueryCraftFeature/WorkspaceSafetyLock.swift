import Observation

@MainActor
@Observable
final class WorkspaceSafetyLock {
    private(set) var isEnabled = true

    func enable() {
        isEnabled = true
    }

    func disable() {
        isEnabled = false
    }

    func executionPolicy(
        for plan: SQLExecutionBatchPlan
    ) throws -> SQLExecutionPolicy {
        guard plan.requiresWriteAccess else { return .readOnly }
        guard !isEnabled else {
            throw plan.containsUnclassifiedStatement
                ? SQLExecutionPolicyError.unclassifiedStatement
                : SQLExecutionPolicyError.safetyLockEnabled
        }
        return .writesAllowed
    }
}
