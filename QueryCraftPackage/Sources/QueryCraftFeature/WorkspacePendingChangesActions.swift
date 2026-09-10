struct WorkspacePendingChangesActions: Equatable {
    let hasChanges: Bool
    let previewContent: WorkspacePendingChangesPreview
    let canCommit: Bool
    let isCommitting: Bool
    let discard: @MainActor @Sendable () -> Void
    let preview: @MainActor @Sendable () -> Void
    let commit: @MainActor @Sendable () -> Void

    init(
        hasChanges: Bool,
        previewContent: WorkspacePendingChangesPreview,
        canCommit: Bool = true,
        isCommitting: Bool,
        discard: @escaping @MainActor @Sendable () -> Void,
        preview: @escaping @MainActor @Sendable () -> Void,
        commit: @escaping @MainActor @Sendable () -> Void
    ) {
        self.hasChanges = hasChanges
        self.previewContent = previewContent
        self.canCommit = canCommit
        self.isCommitting = isCommitting
        self.discard = discard
        self.preview = preview
        self.commit = commit
    }

    init(
        hasChanges: Bool,
        statements: [WorkspaceSQLPreviewStatement],
        canCommit: Bool = true,
        isCommitting: Bool,
        discard: @escaping @MainActor @Sendable () -> Void,
        preview: @escaping @MainActor @Sendable () -> Void,
        commit: @escaping @MainActor @Sendable () -> Void
    ) {
        self.hasChanges = hasChanges
        previewContent = .sql(statements)
        self.canCommit = canCommit
        self.isCommitting = isCommitting
        self.discard = discard
        self.preview = preview
        self.commit = commit
    }

    init(
        hasChanges: Bool,
        redisCommands: [RedisCommandInvocation],
        canCommit: Bool = true,
        isCommitting: Bool,
        discard: @escaping @MainActor @Sendable () -> Void,
        preview: @escaping @MainActor @Sendable () -> Void,
        commit: @escaping @MainActor @Sendable () -> Void
    ) {
        self.hasChanges = hasChanges
        previewContent = .redis(redisCommands)
        self.canCommit = canCommit
        self.isCommitting = isCommitting
        self.discard = discard
        self.preview = preview
        self.commit = commit
    }

    init(
        hasChanges: Bool,
        elasticsearchRequests: [WorkspaceRequest],
        canCommit: Bool = true,
        isCommitting: Bool,
        discard: @escaping @MainActor @Sendable () -> Void,
        preview: @escaping @MainActor @Sendable () -> Void,
        commit: @escaping @MainActor @Sendable () -> Void
    ) {
        self.hasChanges = hasChanges
        previewContent = .elasticsearch(elasticsearchRequests)
        self.canCommit = canCommit
        self.isCommitting = isCommitting
        self.discard = discard
        self.preview = preview
        self.commit = commit
    }

    var statements: [WorkspaceSQLPreviewStatement] {
        guard case .sql(let statements) = previewContent else { return [] }
        return statements
    }

    var canPreview: Bool {
        !previewContent.isEmpty
    }

    static func == (
        lhs: WorkspacePendingChangesActions,
        rhs: WorkspacePendingChangesActions
    ) -> Bool {
        lhs.hasChanges == rhs.hasChanges
            && lhs.previewContent == rhs.previewContent
            && lhs.canCommit == rhs.canCommit
            && lhs.isCommitting == rhs.isCommitting
    }
}
