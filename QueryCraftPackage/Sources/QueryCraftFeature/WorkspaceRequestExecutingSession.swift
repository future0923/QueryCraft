#if os(iOS)
import QueryCraftMobileCore
#endif
public protocol WorkspaceRequestExecutingSession: WorkspaceSession {
    func executeRequest(
        _ request: WorkspaceRequest
    ) async throws -> WorkspaceRequestExecutionResult

    func executeRequest(
        _ request: WorkspaceRequest,
        policy: WorkspaceRequestExecutionPolicy
    ) async throws -> WorkspaceRequestExecutionResult
}

public extension WorkspaceRequestExecutingSession {
    func executeRequest(_ request: WorkspaceRequest, policy: WorkspaceRequestExecutionPolicy) async throws -> WorkspaceRequestExecutionResult {
        // Legacy implementers never acquire write access through a default implementation.
        try WorkspaceReadOnlyRequestValidator.validate(request)
        return try await executeRequest(request)
    }
}
