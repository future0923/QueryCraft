struct WorkspaceGridSearchCommandActions {
    let search: @MainActor @Sendable () -> Void
    let dismiss: (@MainActor @Sendable () -> Void)?
    let isPresented: (@MainActor @Sendable () -> Bool)?

    init(
        search: @escaping @MainActor @Sendable () -> Void,
        dismiss: (@MainActor @Sendable () -> Void)? = nil,
        isPresented: (@MainActor @Sendable () -> Bool)? = nil
    ) {
        self.search = search
        self.dismiss = dismiss
        self.isPresented = isPresented
    }
}
