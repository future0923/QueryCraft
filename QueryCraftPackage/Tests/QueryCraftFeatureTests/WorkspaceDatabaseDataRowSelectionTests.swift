import Foundation
import Testing

@testable import QueryCraftFeature

struct WorkspaceDatabaseDataRowSelectionTests {
    @Test
    func deletingMiddleRowSelectsNextActiveRow() {
        #expect(
            WorkspaceDatabaseDataRowSelection.nearestActiveIndex(
                startingAt: 1,
                totalRowCount: 4,
                excludedRowIndexes: [1]
            ) == 2
        )
    }

    @Test
    func deletingLastRowSelectsPreviousActiveRow() {
        #expect(
            WorkspaceDatabaseDataRowSelection.nearestActiveIndex(
                startingAt: 2,
                totalRowCount: 3,
                excludedRowIndexes: [2]
            ) == 1
        )
    }

    @Test
    func deletingSeveralRowsSkipsEveryPendingDeletion() {
        #expect(
            WorkspaceDatabaseDataRowSelection.nearestActiveIndex(
                startingAt: 1,
                totalRowCount: 5,
                excludedRowIndexes: [1, 2, 3]
            ) == 4
        )
    }

    @Test
    func deletingDraftRowUsesTheRowShiftedIntoItsPlace() {
        #expect(
            WorkspaceDatabaseDataRowSelection.nearestActiveIndex(
                startingAt: 3,
                totalRowCount: 4,
                excludedRowIndexes: []
            ) == 3
        )
    }

    @Test
    func deletingEveryRowClearsSelection() {
        #expect(
            WorkspaceDatabaseDataRowSelection.nearestActiveIndex(
                startingAt: 0,
                totalRowCount: 2,
                excludedRowIndexes: [0, 1]
            ) == nil
        )
    }
}
