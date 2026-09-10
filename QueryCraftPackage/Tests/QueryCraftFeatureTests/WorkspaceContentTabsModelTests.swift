import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceContentTabsModelTests {
    @Test
    func eachDistinctDatabaseObjectKeepsItsOwnTab() {
        let model = WorkspaceContentTabsModel()
        let users = selection("users")
        let orders = selection("orders")

        model.open(users)
        model.open(orders)

        #expect(model.contentItems.map(\.id) == [
            .databaseObject(users),
            .databaseObject(orders),
        ])
        #expect(model.selectedContentID == .databaseObject(orders))
    }

    @Test
    func clickingAnAlreadyOpenObjectSelectsWithoutDuplicatingIt() {
        let model = WorkspaceContentTabsModel()
        let users = selection("users")
        let orders = selection("orders")

        model.open(users)
        model.open(orders)
        model.open(users)

        #expect(model.contentItems.map(\.id) == [
            .databaseObject(users),
            .databaseObject(orders),
        ])
        #expect(model.selectedContentID == .databaseObject(users))
    }

    @Test
    func reorderingAndCyclicSelectionUseStableIDs() {
        let model = WorkspaceContentTabsModel()
        let selections = ["a", "b", "c"].map(selection)
        for selection in selections {
            model.open(selection)
        }

        model.move(.databaseObject(selections[0]), to: 2)
        #expect(model.contentItems.map(\.id) == [
            .databaseObject(selections[1]),
            .databaseObject(selections[2]),
            .databaseObject(selections[0]),
        ])

        model.select(at: 0)
        model.select(offsetBy: -1)
        #expect(model.selectedContentID == .databaseObject(selections[0]))
        model.select(offsetBy: 1)
        #expect(model.selectedContentID == .databaseObject(selections[1]))
    }

    @Test
    func closeActionsAndNeighborSelectionFollowCurrentOrder() {
        let model = WorkspaceContentTabsModel()
        let selections = ["a", "b", "c", "d"].map(selection)
        for selection in selections { model.open(selection) }
        model.select(.databaseObject(selections[1]))

        #expect(model.contentIDs(for: .closeToRight(.databaseObject(selections[1]))) == [
            .databaseObject(selections[2]),
            .databaseObject(selections[3]),
        ])
        #expect(model.contentIDs(for: .closeOthers(.databaseObject(selections[1]))).count == 3)

        let replacement = model.removeContent(.databaseObject(selections[1]))
        #expect(replacement == .databaseObject(selections[2]))
    }

    private func selection(_ name: String) -> WorkspaceDatabaseObjectSelection {
        WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: name,
            kind: .table
        )
    }
}
