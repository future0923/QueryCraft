import Foundation
import Testing
@testable import QueryCraftFeature

struct InMemoryConnectionProfileRepositoryTests {
    @Test func moveGroupPersistsRequestedOrder() async throws {
        let first = makeGroup(name: "First", sortIndex: 0)
        let second = makeGroup(name: "Second", sortIndex: 1)
        let repository = InMemoryConnectionProfileRepository(
            groups: [first, second]
        )

        try await repository.moveGroup(
            id: second.id,
            beforeGroupID: first.id
        )

        let snapshot = try await repository.fetchManagementSnapshot()
        #expect(snapshot.groups.map(\.id) == [second.id, first.id])
        #expect(snapshot.groups.map(\.sortIndex) == [0, 1])
    }

    private func makeGroup(
        name: String,
        sortIndex: Int
    ) -> ConnectionGroup {
        ConnectionGroup(
            id: UUID(),
            name: name,
            sortIndex: sortIndex,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }
}
