import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceContentTabStripLayoutTests {
    @Test("Legacy tabs preserve intrinsic widths when space is available")
    func preservesIntrinsicWidths() {
        let widths = WorkspaceContentTabStripLayout.fittingWidths(
            ideal: [120, 180],
            minimum: [60, 60],
            availableWidth: 600
        )

        #expect(widths == [120, 180])
    }

    @Test("Legacy tabs compress proportionally to fit available space")
    func compressesProportionally() {
        let widths = WorkspaceContentTabStripLayout.fittingWidths(
            ideal: [120, 180],
            minimum: [60, 60],
            availableWidth: 210
        )

        #expect(widths.count == 2)
        #expect(abs(widths.reduce(0, +) - 210) < 0.001)
        #expect(widths[0] >= 60)
        #expect(widths[1] >= 60)
    }

    @Test("Legacy tabs keep readable minima and overflow when necessary")
    func preservesMinimumWidths() {
        let widths = WorkspaceContentTabStripLayout.fittingWidths(
            ideal: [120, 180],
            minimum: [70, 80],
            availableWidth: 100
        )

        #expect(widths == [70, 80])
    }
}
