#if os(iOS)
import QueryCraftMobileCore
#endif
/// An additive capability: older API 5 drivers keep using their existing INSERT path.
/// New driver bundles referencing this capability require app version 0.1.10 or newer.
public protocol WorkspaceNativeBulkTransferSession: WorkspaceSession {
    func nativeBulkTransferFormat() async throws -> WorkspaceNativeBulkFormat?
    func executeNativeBulkTransfer(sql: String, token: String,
                                   stream: WorkspaceNativeBulkStream) async throws -> Int
}

/// PostgreSQL can forward COPY text unchanged when both column layouts match.
public protocol WorkspaceNativeCopySourceSession: WorkspaceSession {
    func executeNativeCopyOut(sql: String, stream: WorkspaceNativeBulkStream,
                              onProgress: @escaping @Sendable (Int) async -> Void) async throws -> Int
}

/// Transfer-only unbuffered source reads. Normal SQL/table result paths are unchanged.
public protocol WorkspaceNativeRowSourceSession: WorkspaceSession {
    func streamTransferRows(sql: String, batchSize: Int,
                            onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> Int
}

