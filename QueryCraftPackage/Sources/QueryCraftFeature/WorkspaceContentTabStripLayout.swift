import AppKit

@MainActor
enum WorkspaceContentTabStripLayout {
    static let trackPadding: CGFloat = 2
    static let stripInset: CGFloat = 8
    static let tabHeight = nativeControlHeight(for: .large)
    static let trackHeight = tabHeight + trackPadding * 2
    static let bandHeight = trackHeight + stripInset
    static let minimumTabWidth: CGFloat = 120
    static let separatorHeight: CGFloat = 16
    static let accessoryWidth: CGFloat = 16
    static let accessoryInset: CGFloat = 5
    static let draggingOpacity: CGFloat = 0.45
    static let hairline: CGFloat = 0.5

    private static func nativeControlHeight(
        for controlSize: NSControl.ControlSize
    ) -> CGFloat {
        let button = NSButton(title: "Tab", target: nil, action: nil)
        button.controlSize = controlSize
        button.bezelStyle = .rounded
        button.sizeToFit()
        return ceil(button.fittingSize.height)
    }

    static func tabWidth(forTrack width: CGFloat, count: Int) -> CGFloat {
        max(
            (width - trackPadding * 2) / CGFloat(max(count, 1)),
            minimumTabWidth
        )
    }

    nonisolated static func fittingWidths(
        ideal: [CGFloat],
        minimum: [CGFloat],
        availableWidth: CGFloat
    ) -> [CGFloat] {
        guard ideal.count == minimum.count, !ideal.isEmpty else { return [] }

        let normalized = zip(ideal, minimum).map { ideal, minimum in
            (ideal: max(ideal, minimum), minimum: max(minimum, 0))
        }
        let idealTotal = normalized.reduce(0) { $0 + $1.ideal }
        guard idealTotal > availableWidth else {
            return normalized.map(\.ideal)
        }

        let minimumTotal = normalized.reduce(0) { $0 + $1.minimum }
        guard minimumTotal < availableWidth else {
            return normalized.map(\.minimum)
        }

        let compressibleTotal = idealTotal - minimumTotal
        let compressionRatio = (idealTotal - availableWidth)
            / compressibleTotal
        return normalized.map {
            $0.ideal - ($0.ideal - $0.minimum) * compressionRatio
        }
    }

    static func showsSeparator(
        before index: Int,
        ids: [WorkspaceContentTabID],
        selectedID: WorkspaceContentTabID?,
        hoveredID: WorkspaceContentTabID?,
        isReordering: Bool
    ) -> Bool {
        guard !isReordering, index > 0, ids.indices.contains(index) else {
            return false
        }
        let leading = ids[index - 1]
        let trailing = ids[index]
        return leading != selectedID && trailing != selectedID
            && leading != hoveredID && trailing != hoveredID
    }
}
