import Foundation

protocol WorkspaceRestorationRepository: Sendable {
    func fetchAll() async throws -> [WorkspaceRestorationState]
    func fetch(id: WorkspaceRestorationState.ID) async throws
        -> WorkspaceRestorationState?
    func save(_ state: WorkspaceRestorationState) async throws
    func delete(id: WorkspaceRestorationState.ID) async throws
}
