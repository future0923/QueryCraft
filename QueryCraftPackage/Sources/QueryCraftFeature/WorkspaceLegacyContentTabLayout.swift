import SwiftUI

struct WorkspaceLegacyContentTabLayout: Layout {
    let availableWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let measurements = measurements(
            for: subviews,
            proposedHeight: proposal.height
        )
        return CGSize(
            width: measurements.widths.reduce(0, +),
            height: measurements.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let measurements = measurements(
            for: subviews,
            proposedHeight: bounds.height
        )
        var x = bounds.minX
        for (subview, width) in zip(subviews, measurements.widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(
                    width: width,
                    height: measurements.height
                )
            )
            x += width
        }
    }

    private func measurements(
        for subviews: Subviews,
        proposedHeight: CGFloat?
    ) -> (widths: [CGFloat], height: CGFloat) {
        let idealSizes = subviews.map {
            $0.sizeThatFits(
                ProposedViewSize(width: nil, height: proposedHeight)
            )
        }
        let minimumSizes = subviews.map {
            $0.sizeThatFits(
                ProposedViewSize(width: 0, height: proposedHeight)
            )
        }
        return (
            WorkspaceContentTabStripLayout.fittingWidths(
                ideal: idealSizes.map(\.width),
                minimum: minimumSizes.map(\.width),
                availableWidth: availableWidth
            ),
            idealSizes.map(\.height).max() ?? 0
        )
    }
}
