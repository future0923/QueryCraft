import Foundation

actor InMemoryWorkspaceRestorationRepository:
    WorkspaceRestorationRepository
{
    private var states: [WorkspaceRestorationState]

    init(states: [WorkspaceRestorationState] = []) {
        self.states = states
    }

    func fetchAll() async throws -> [WorkspaceRestorationState] {
        states.sorted(by: Self.restorationOrder)
    }

    func fetch(
        id: WorkspaceRestorationState.ID
    ) async throws -> WorkspaceRestorationState? {
        states.first { $0.id == id }
    }

    func save(_ state: WorkspaceRestorationState) async throws {
        states.removeAll { $0.id == state.id }
        states.append(state)
    }

    func delete(id: WorkspaceRestorationState.ID) async throws {
        states.removeAll { $0.id == id }
    }

    private static func restorationOrder(
        _ left: WorkspaceRestorationState,
        _ right: WorkspaceRestorationState
    ) -> Bool {
        if left.createdAt != right.createdAt {
            return left.createdAt < right.createdAt
        }
        return left.id.uuidString < right.id.uuidString
    }
}
