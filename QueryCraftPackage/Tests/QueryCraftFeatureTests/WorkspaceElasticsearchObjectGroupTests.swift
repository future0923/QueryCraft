import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceElasticsearchObjectGroupTests {
    @Test
    func classifiesResourcesWithoutChangingTheirOrder() {
        let objects = [
            WorkspaceDatabaseObject(
                name: "orders-write",
                kind: .elasticsearchAlias
            ),
            WorkspaceDatabaseObject(
                name: "orders-2026",
                kind: .elasticsearchIndex
            ),
            WorkspaceDatabaseObject(
                name: "logs-app",
                kind: .elasticsearchDataStream
            ),
            WorkspaceDatabaseObject(
                name: "orders-read",
                kind: .elasticsearchAlias
            ),
        ]

        #expect(
            WorkspaceDatabaseItems.objects(
                of: .elasticsearchAlias,
                in: objects
            ).map(\.name) == ["orders-write", "orders-read"]
        )
        #expect(
            WorkspaceDatabaseItems.objects(
                of: .elasticsearchDataStream,
                in: objects
            ).map(\.name) == ["logs-app"]
        )
        #expect(
            WorkspaceDatabaseItems.objects(
                of: .elasticsearchIndex,
                in: objects
            ).map(\.name) == ["orders-2026"]
        )
    }

    @Test
    func projectSearchSupportsOrderedFuzzyMatchesAndRanksStrongerMatches() {
        let objects = [
            WorkspaceDatabaseObject(
                name: "business-order-history",
                kind: .elasticsearchIndex
            ),
            WorkspaceDatabaseObject(
                name: "bookings",
                kind: .elasticsearchIndex
            ),
            WorkspaceDatabaseObject(
                name: "bo",
                kind: .elasticsearchAlias
            ),
            WorkspaceDatabaseObject(
                name: "billing_operations",
                kind: .elasticsearchDataStream
            ),
            WorkspaceDatabaseObject(
                name: "orders",
                kind: .elasticsearchIndex
            ),
        ]

        #expect(
            WorkspaceDatabaseItems.objects(
                in: objects,
                matching: "bo"
            ).map(\.name) == [
                "bo",
                "bookings",
                "billing_operations",
                "business-order-history",
            ]
        )
    }
}
