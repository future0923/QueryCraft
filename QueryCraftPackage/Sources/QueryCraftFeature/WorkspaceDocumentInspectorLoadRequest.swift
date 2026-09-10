/// A console write can invalidate a document even when its selected identity is unchanged.
struct WorkspaceDocumentInspectorLoadRequest: Equatable, Sendable {
    let reference: WorkspaceDocumentReference?
    let serverRevision: Int
}
