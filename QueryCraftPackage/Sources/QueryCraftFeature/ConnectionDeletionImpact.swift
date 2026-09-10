struct ConnectionDeletionImpact: Equatable, Sendable {
    let connectionProfileCount: Int
    let savedQueryCount: Int
    let recoverableDraftCount: Int
    let workspaceRestorationCount: Int
    let storedCredentialCount: Int
}
