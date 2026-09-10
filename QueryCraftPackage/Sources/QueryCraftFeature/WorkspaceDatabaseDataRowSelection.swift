import Foundation

enum WorkspaceDatabaseDataRowSelection {
    static func nearestActiveIndex(
        startingAt preferredIndex: Int,
        totalRowCount: Int,
        excludedRowIndexes: IndexSet
    ) -> Int? {
        guard totalRowCount > 0 else { return nil }
        let forwardStart = min(max(0, preferredIndex), totalRowCount)
        if let next = (forwardStart..<totalRowCount).first(where: {
            !excludedRowIndexes.contains($0)
        }) {
            return next
        }
        return (0..<forwardStart).reversed().first(where: {
            !excludedRowIndexes.contains($0)
        })
    }
}
